provider "aws" {
    region     = "us-east-1"
    access_key = "AKIAR4OIVUZIZRCKR4QW"
    secret_key = "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"
}


locals {
    id_vpc = aws_vpc.prod_vpc.id
    eip_id = "eipalloc-0cfa1781be9492633"
    def_addr = "0.0.0.0/0"
}

#vpc configuration
resource "aws_vpc" "prod_vpc" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "prod_vpc"
  }
}

resource "aws_internet_gateway" "my_igw" {
  vpc_id   = local.id_vpc
  tags = {
      Name = "prod_igw"
  }
}

#create codecommit repo
resource "aws_codecommit_repository" "test" {
    repository_name = "django_repo"
    description     = "django web application git repository"
}

################## AWS CODEBUILD CONF ##################

#create nat gateway
resource "aws_nat_gateway" "nat_codebuild" {
    allocation_id = local.eip_id
    subnet_id     = aws_subnet.public_subnet_codebuild.id
    tags = {
      Name = "nat_codebuild"
    }
   
}

#subnets configuration for Codebuild
resource "aws_subnet" "public_subnet_codebuild" {
  vpc_id                  = local.id_vpc
  cidr_block              = "192.168.10.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
      Name = "build_pub_sub"
  }
}

resource "aws_subnet" "private_subnet_codebuild" {
  vpc_id                  = local.id_vpc
  cidr_block              = "192.168.11.0/24"
  availability_zone       = "us-east-1a"
  tags = {
      Name = "build_priv_sub"
  }
}

resource "aws_route_table" "codebuild_pub_sub_route" {
    vpc_id = local.id_vpc

    route {
        cidr_block = local.def_addr
        gateway_id = aws_internet_gateway.my_igw.id
    }
    tags = {
        Name = "codebuild_pub_sub_route"
    }
}

resource "aws_route_table" "codebuild_priv_sub_route" {
    vpc_id = local.id_vpc

    route {
        cidr_block     = local.def_addr
        nat_gateway_id = aws_nat_gateway.nat_codebuild.id
    }
    tags = {
        Name = "codebuild_priv_sub_route"
    }
}

resource "aws_route_table_association" "pub_route_asso" {
    subnet_id      = aws_subnet.public_subnet_codebuild.id
    route_table_id = aws_route_table.codebuild_pub_sub_route.id
}

resource "aws_route_table_association" "priv_route_asso" {
    subnet_id      = aws_subnet.private_subnet_codebuild.id
    route_table_id = aws_route_table.codebuild_priv_sub_route.id
}

#security group for codebuild
resource "aws_security_group" "codebuild_sg" {
    name   = "codebuild_sg"
    vpc_id = local.id_vpc

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [local.def_addr]
    }
    tags = {
      Name = "codebuild_sg"
    }
}

#CodeBuild IAM role config
resource "aws_iam_role" "django_codebuild_dock_role" {
    name = "django_codebuild_dock_role"

    assume_role_policy = <<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Action": "sts:AssumeRole",
          "Principal": {
            "Service": "codebuild.amazonaws.com"
          },
          "Effect": "Allow",
          "Sid": ""
        }
      ]
    }
EOF
}

resource "aws_iam_role_policy" "codebuild_role_policy" {
    role = aws_iam_role.django_codebuild_dock_role.name

    policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
        {
            "Effect": "Allow",
            "Resource": [
                "*"
            ],
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ]
        },
        {
            "Effect": "Allow",
            "Resource": [
                "arn:aws:codecommit:us-east-1:129806739025:django_repo"
            ],
            "Action": [
                "codecommit:GitPull"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateNetworkInterface",
                "ec2:DescribeDhcpOptions",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DeleteNetworkInterface",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeVpcs"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Resource": [
                "arn:aws:s3:::codepipeline-us-east-1-*"
            ],
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:GetBucketAcl",
                "s3:GetBucketLocation"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateNetworkInterfacePermission"
            ],
            "Resource": "arn:aws:ec2:us-east-1:129806739025:network-interface/*",
            "Condition": {
                "StringEquals": {
                    "ec2:Subnet": [
                        "arn:aws:ec2:us-east-1:129806739025:subnet/subnet-002073080d5c66ac1"
                    ],
                    "ec2:AuthorizedService": "codebuild.amazonaws.com"
                }
            }
        },
        {
            "Action": [
                "ecr:BatchCheckLayerAvailability",
                "ecr:CompleteLayerUpload",
                "ecr:GetAuthorizationToken",
                "ecr:InitiateLayerUpload",
                "ecr:PutImage",
                "ecr:UploadLayerPart"
                ],
            "Resource": "*", 
            "Effect": "Allow"
        }
    ]
}   
POLICY
}

#create codebuild project
resource "aws_codebuild_project" "django_codebuild_project" {

    name         = "django_codebuild_project"
    description  = "build docker image from django app and push to ecr"
    service_role = aws_iam_role.django_codebuild_dock_role.arn

    artifacts {
      type = "NO_ARTIFACTS"
    }

    environment { 
      compute_type    = "BUILD_GENERAL1_SMALL"
      image           = "aws/codebuild/standard:1.0"
      type            = "LINUX_CONTAINER"
      privileged_mode = true
    }

    source {
      type     = "CODECOMMIT"
      location = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/django_repo"
    }

    vpc_config {
      security_group_ids = [aws_security_group.codebuild_sg.id]
      subnets            = [aws_subnet.private_subnet_codebuild.id]
      vpc_id             = local.id_vpc
    }
  
}


################## END OF CODEBUILD CONF ##################

#create ECR repo for ou docker images and lifecycle policy to delete the previous images
resource "aws_ecr_repository" "django_dock_repo" {
    name = "django_dock"  
}

resource "aws_ecr_lifecycle_policy" "lifecycle_ecr_policy" {
    repository = aws_ecr_repository.django_dock_repo.name

    policy = <<EOF
{
    "rules": [
        {
            "rulePriority": 1,
            "description": "Expire images older than 1 days",
            "selection": {
                "tagStatus": "untagged",
                "countType": "sinceImagePushed",
                "countUnit": "days",
                "countNumber": 1
            },
            "action": {
                "type": "expire"
            }
        }
    ]
}
EOF  
}

################## Load balancer and subnet config for deployment ##################

resource "aws_subnet" "public_subnet_prod1" {
  vpc_id                  = local.id_vpc
  cidr_block              = "192.168.4.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
      Name = "prod_sub1"
  }
}

resource "aws_subnet" "public_subnet_prod2" {
  vpc_id                  = local.id_vpc
  cidr_block              = "192.168.5.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = {
      Name = "prod_sub2"
  }
}

resource "aws_route_table_association" "pub_route_asso_prod1" {
    subnet_id      = aws_subnet.public_subnet_prod1.id
    route_table_id = aws_route_table.codebuild_pub_sub_route.id
}

resource "aws_route_table_association" "pub_route_asso_prod2" {
    subnet_id      = aws_subnet.public_subnet_prod2.id
    route_table_id = aws_route_table.codebuild_pub_sub_route.id
}

resource "aws_security_group" "alb_sg" {
    name   = "alb_sg"
    vpc_id = local.id_vpc
    
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = [local.def_addr]
    }
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [local.def_addr]
    }
    tags = {
      Name = "alb_sg"
    }
}

resource "aws_lb" "app_load_balancer" {

    name               = "prod-ALB"
    internal           = false
    load_balancer_type = "application"
    security_groups    = [ aws_security_group.alb_sg.id ]
    subnets            = [aws_subnet.public_subnet_prod1.id, aws_subnet.public_subnet_prod2.id]
    ip_address_type    = "ipv4"
    
    tags = {
      Name = "prod_alb"
    }
}

resource "aws_lb_target_group" "alb_target_grp1" {
    name        = "alb-target-grp1"
    port        = 80
    protocol    = "HTTP"
    target_type = "ip"
    vpc_id      = local.id_vpc
  
}

resource "aws_lb_target_group" "alb_target_grp2" {
    name        = "alb-target-grp2"
    port        = 8080
    protocol    = "HTTP"
    target_type = "ip"
    vpc_id      = local.id_vpc
  
}

resource "aws_lb_listener" "alb_listener1" {
    load_balancer_arn = aws_lb.app_load_balancer.arn
    port              = "80"
    protocol          = "HTTP"

    default_action {
      type             = "forward"
      target_group_arn = aws_lb_target_group.alb_target_grp1.arn
    }
  
}

resource "aws_lb_listener" "alb_listener2" {
    load_balancer_arn = aws_lb.app_load_balancer.arn
    port              = "8080"
    protocol          = "HTTP"

    default_action {
      type             = "forward"
      target_group_arn = aws_lb_target_group.alb_target_grp2.arn
    }
  
}


################## ECS CONFIG ##################

resource "aws_ecs_task_definition" "task_def" {

    family                   = "task_def"
    execution_role_arn       = "arn:aws:iam::129806739025:role/ecsTaskExecutionRole"
    container_definitions    = file("container_def.json")
    requires_compatibilities = [ "FARGATE" ]
    network_mode             = "awsvpc"
    cpu                      = "256"
    memory                   = "512"
  
}

resource "aws_ecs_cluster" "prod_cluster" {
    name               = "prod-cluster"
    capacity_providers = ["FARGATE"]
  
}

resource "aws_ecs_service" "prod_service" {

    name                = "prod-service"
    cluster             = aws_ecs_cluster.prod_cluster.id
    task_definition     = aws_ecs_task_definition.task_def.id
    desired_count       = 1  
    launch_type         = "FARGATE"
    scheduling_strategy = "REPLICA"

    load_balancer {
        target_group_arn = aws_lb_target_group.alb_target_grp1.arn
        container_name   = "django_web_app"  
        container_port   = 80
    }

    deployment_controller {
        type = "CODE_DEPLOY"
    }

    network_configuration {
        subnets         = [aws_subnet.public_subnet_prod1.id, aws_subnet.public_subnet_prod2.id]
        security_groups = [aws_security_group.alb_sg.id]
        assign_public_ip = true
    }
}

################## CODEDEPLOY CONFIG ##################

resource "aws_codedeploy_app" "django_deploy" {
    compute_platform = "ECS"
    name             = "django-deploy"  
}

#codedeploy IAM role

resource "aws_iam_role" "codedeploy_ECS_role" {

    name = "codedeploy_ECS_role"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "codedeploy.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "AWSCodeDeployRole_attach" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.codedeploy_ECS_role.name
}

resource "aws_iam_role_policy" "describe_ecs_policy" {
    role = aws_iam_role.codedeploy_ECS_role.name

    policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "ecs:DescribeServices",
                "ecs:CreateTaskSet",
                "ecs:UpdateServicePrimaryTaskSet",
                "ecs:DeleteTaskSet",
                "elasticloadbalancing:DescribeTargetGroups",
                "elasticloadbalancing:DescribeListeners",
                "elasticloadbalancing:ModifyListener",
                "elasticloadbalancing:DescribeRules",
                "elasticloadbalancing:ModifyRule",
                "lambda:InvokeFunction",
                "cloudwatch:DescribeAlarms",
                "sns:Publish",
                "s3:GetObject",
                "s3:GetObjectVersion"
            ],
            "Resource": "*",
            "Effect": "Allow"
        },
        {
            "Action": [
                "iam:PassRole"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Condition": {
                "StringLike": {
                    "iam:PassedToService": [
                        "ecs-tasks.amazonaws.com"
                    ]
                }
            }
        }
    ]
}
POLICY  
}

#create codedeploy deployment group
resource "aws_codedeploy_deployment_group" "prod_deployment_grp" {

    app_name               = aws_codedeploy_app.django_deploy.name
    deployment_group_name  = "prod-deployment-grp"
    service_role_arn       = aws_iam_role.codedeploy_ECS_role.arn
    deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

    ecs_service {
        cluster_name = aws_ecs_cluster.prod_cluster.name
        service_name = aws_ecs_service.prod_service.name
    }

    deployment_style {
        deployment_option = "WITH_TRAFFIC_CONTROL"
        deployment_type   = "BLUE_GREEN"
    }

    load_balancer_info {
        target_group_pair_info {
            prod_traffic_route {
                listener_arns = [aws_lb_listener.alb_listener1.arn]
            }
            test_traffic_route {
                listener_arns = [aws_lb_listener.alb_listener2.arn]
            }
            target_group {
                name = aws_lb_target_group.alb_target_grp1.name
            }
            target_group {
                name = aws_lb_target_group.alb_target_grp2.name
            }
        }
    }

    blue_green_deployment_config {
        deployment_ready_option {
            action_on_timeout = "CONTINUE_DEPLOYMENT"
        }
        terminate_blue_instances_on_deployment_success {
            action = "TERMINATE"
        }
    }
    
    auto_rollback_configuration {
        enabled = true
        events  = ["DEPLOYMENT_FAILURE"]
    }
}