#
# Security group resources
#
resource "aws_security_group" "main" {
  vpc_id = "${var.vpc_id}"

  tags {
    Name        = "sg${var.name}LoadBalancer"
    Project     = "${var.project}"
    Environment = "${var.environment}"
  }
}

#
# ALB resources
#
resource "aws_alb" "main" {
  security_groups = ["${concat(var.security_group_ids, list(aws_security_group.main.id))}"]
  subnets         = ["${var.public_subnet_ids}"]
  name            = "alb${var.environment}${var.name}"

  access_logs {
    bucket = "${var.access_log_bucket}"
    prefix = "${var.access_log_prefix}"
  }

  tags {
    Name        = "alb${var.environment}${var.name}"
    Project     = "${var.project}"
    Environment = "${var.environment}"
  }
}

resource "aws_alb_target_group" "main" {
  name = "tg${var.environment}${var.name}"

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = "${var.health_check_path}"
    unhealthy_threshold = "2"
  }

  port     = "${var.port}"
  protocol = "HTTP"
  vpc_id   = "${var.vpc_id}"

  tags {
    Name        = "tg${var.environment}${var.name}"
    Project     = "${var.project}"
    Environment = "${var.environment}"
  }
}

resource "aws_alb_listener" "https" {
  load_balancer_arn = "${aws_alb.main.id}"
  port              = "443"
  protocol          = "HTTPS"

  certificate_arn = "${var.ssl_certificate_arn}"

  default_action {
    target_group_arn = "${aws_alb_target_group.main.id}"
    type             = "forward"
  }
}

#
# ECS resources
#
resource "aws_ecs_service" "main" {
  lifecycle {
    create_before_destroy = true
  }

  name                               = "${var.environment}${var.name}"
  cluster                            = "${var.cluster_name}"
  task_definition                    = "${var.task_definition_id}"
  desired_count                      = "${var.desired_count}"
  deployment_minimum_healthy_percent = "${var.deployment_min_healthy_percent}"
  deployment_maximum_percent         = "${var.deployment_max_percent}"
  iam_role                           = "${var.ecs_service_role_name}"

  load_balancer {
    target_group_arn = "${aws_alb_target_group.main.id}"
    container_name   = "${var.container_name}"
    container_port   = "${var.container_port}"
  }
}

#
# Application AutoScaling resources
#
resource "aws_appautoscaling_target" "main" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = "${var.min_count}"
  max_capacity       = "${var.max_count}"

  depends_on = [
    "aws_ecs_service.main",
  ]
}

resource "aws_appautoscaling_policy" "up" {
  name               = "appScalingPolicy${var.environment}${var.name}ScaleUp"
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = "${var.scale_up_cooldown_seconds}"
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }

  depends_on = [
    "aws_appautoscaling_target.main",
  ]
}

resource "aws_appautoscaling_policy" "down" {
  name               = "appScalingPolicy${var.environment}${var.name}ScaleDown"
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = "${var.scale_down_cooldown_seconds}"
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }

  depends_on = [
    "aws_appautoscaling_target.main",
  ]
}

resource "aws_security_group_rule" "app_lb_https_ingress" {
  type        = "ingress"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]

  security_group_id = "${module.app_web_service.lb_security_group_id}"
}

resource "aws_ecs_task_definition" "app" {
  lifecycle {
    create_before_destroy = true
  }

  family                = "ProductionApp"
  container_definitions = "..."
}

module "app_web_service" {
  source = "github.com/azavea/terraform-aws-ecs-web-service?ref=0.4.0"

  name                = "App"
  vpc_id              = "vpc-..."
  public_subnet_ids   = ["subnet-...", "subnet-..."]
  access_log_bucket   = "logs-bucket"
  access_log_prefix   = "ALB"
  health_check_path   = "/health-check/"
  port                = "8080"
  ssl_certificate_arn = "arn..."

  cluster_name                   = "default"
  task_definition_id             = "${aws_ecs_task_definition.app.family}:${aws_ecs_task_definition.app.revision}"
  desired_count                  = "1"
  min_count                      = "1"
  max_count                      = "2"
  scale_up_cooldown_seconds      = "300"
  scale_down_cooldown_seconds    = "300"
  deployment_min_healthy_percent = "100"
  deployment_max_percent         = "200"
  container_name                 = "django"
  container_port                 = "8080"
  
  ecs_service_role_name = "..."

  project     = "${var.project}"
  environment = "${var.environment}"
}

resource "aws_cloudwatch_metric_alarm" "app_service_high_cpu" {
  alarm_name          = "alarmAppCPUUtilizationHigh"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "60"

  dimensions {
    ClusterName = "default"
    ServiceName = "App"
  }

  alarm_actions = ["${module.app_web_service.appautoscaling_policy_scale_up_arn}"]
}

resource "aws_cloudwatch_metric_alarm" "app_service_low_cpu" {
  alarm_name          = "alarmAppCPUUtilizationLow"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "15"

  dimensions {
    ClusterName = "default"
    ServiceName = "App"
  }

  alarm_actions = ["${module.app_web_service.appautoscaling_policy_scale_down_arn}"]
}
