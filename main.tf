provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  region = "eu-west-1"
  name   = "ex-${basename(path.cwd)}"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  container_port = 80

  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/olexade/ecs-free-tier-optimized"
  }
}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws//modules/cluster"

  cluster_name = local.name

  # Capacity provider - autoscaling groups
  default_capacity_provider_use_fargate = false
  autoscaling_capacity_providers = {
    # On-demand instances
    ex_1 = {
      auto_scaling_group_arn         = module.autoscaling["ex_1"].autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 5
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }

      default_capacity_provider_strategy = {
        weight = 60
        base   = 20
      }
    }
  }

  tags = local.tags
}

################################################################################
# Service
################################################################################

module "ecs_service" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = "NGINX"
  cluster_arn = module.ecs_cluster.arn

  # Task Definition
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 256
  capacity_provider_strategy = {
    # On-demand instances
    ex_1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["ex_1"].name
      weight            = 1
      base              = 1
    }
  }

  # Container definition(s)
  container_definitions = {
    ("nginx") = {
      image = "nginx:latest"
      port_mappings = [
        {
          name          = "nginx"
          containerPort = 80
          protocol      = "tcp"
        }
      ]
      entrypoint = [
        "/bin/bash",
        "-c"
      ]
      command = [
        "mkdir -p /usr/share/nginx/html/nginx ; echo '<html lang=\"en\"> <head> <meta charset=\"UTF-8\"> <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"> <title>Current Time</title> <style> body { font-family: Arial, sans-serif; margin-top: 50px; text-align: center; } #time { font-size: 24px; color: #333; } </style> </head> <body> <h1>Current Time</h1> <div id=\"time\"></div> <script> function updateTime() { const now = new Date(); const timeString = now.toLocaleTimeString(); document.getElementById(\"time\").textContent = timeString; } setInterval(updateTime, 1000); updateTime(); </script> </body> </html>' > /usr/share/nginx/html/nginx/index.html && exec nginx -g 'daemon off;'"
      ]

      # Example image used requires access to write to root filesystem
      readonly_root_filesystem = false

      enable_cloudwatch_logging              = true
      create_cloudwatch_log_group            = true
      cloudwatch_log_group_name              = "/aws/ecs/nginx/nginx"
      cloudwatch_log_group_retention_in_days = 7

      log_configuration = {
        logDriver = "awslogs"
      }
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["nginx"].arn
      container_name   = "nginx"
      container_port   = 80
    }
  }

  subnet_ids = module.vpc.public_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = 80
      to_port                  = 80
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
  }

  tags = {
    Name       = "nginx"
    Example    = "nginx"
    Repository = "https://github.com/olexade/ecs-free-tier-optimized"
  }
}

################################################################################
# Service
################################################################################

module "ecs_service_2" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = local.name
  cluster_arn = module.ecs_cluster.arn

  # Task Definition
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 256
  capacity_provider_strategy = {
    # On-demand instances
    ex_1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["ex_1"].name
      weight            = 1
      base              = 1
    }
  }

  # Container definition(s)
  container_definitions = {
    ("docker-labs") = {
      image = "docker/getting-started:latest"
      port_mappings = [
        {
          name          = "docker-labs"
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonly_root_filesystem = false

      enable_cloudwatch_logging              = true
      create_cloudwatch_log_group            = true
      cloudwatch_log_group_name              = "/aws/ecs/${local.name}/docker-labs"
      cloudwatch_log_group_retention_in_days = 7

      log_configuration = {
        logDriver = "awslogs"
      }
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["docker-labs"].arn
      container_name   = "docker-labs"
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
  }

  tags = local.tags
}


################################################################################
# Supporting Resources
################################################################################

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    ex_http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "docker-labs"
      }

      rules = {

        docker-labs = {
          actions = [{
            type = "weighted-forward"
            target_groups = [
              {
                target_group_key = "docker-labs"
              }
            ]
            stickiness = {
              enabled  = true
              duration = 3600
            }
          }]
          conditions = [{
            path_pattern = {
              values = ["/tutorial/*"]
            }
            tags = {
              Name    = "dgs"
              Example = "dgs"
            }
          }]
        }

        nginx = {
          actions = [{
            type = "weighted-forward"
            target_groups = [
              {
                target_group_key = "nginx"
              }
            ]
            stickiness = {
              enabled  = true
              duration = 3600
            }
          }]
          conditions = [{
            path_pattern = {
              values = ["/nginx*"]
            }
          }]
          tags = {
            Name    = "nginx"
            Example = "nginx"
          }
        }

      }
    }
  }

  target_groups = {
    docker-labs = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
    nginx = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }

  tags = local.tags
}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"

  for_each = {
    # On-demand instances
    ex_1 = {
      instance_type              = "t3.micro"
      use_mixed_instances_policy = false
      mixed_instances_policy     = {}

      user_data = <<-EOF
          #!/bin/bash

          # Write ECS configuration
          cat <<'EOT' > /etc/ecs/ecs.config
          ECS_CLUSTER=${local.name}
          ECS_LOGLEVEL=debug
          ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
          ECS_ENABLE_TASK_IAM_ROLE=true
          EOT
      EOF


    }
  }

  name = "${local.name}-${each.key}"

  image_id      = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = each.value.instance_type

  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true

  create_iam_instance_profile = true
  iam_role_name               = local.name
  iam_role_description        = "ECS role for ${local.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for  managed_termination_protection = "ENABLED"
  protect_from_scale_in = true

  # Spot instances
  use_mixed_instances_policy = each.value.use_mixed_instances_policy
  mixed_instances_policy     = each.value.mixed_instances_policy

  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.alb.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  map_public_ip_on_launch = true

  enable_nat_gateway = false

  tags = local.tags
}
