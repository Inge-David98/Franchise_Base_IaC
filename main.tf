provider "aws" {
  profile = "dev-local"
  region  = "us-east-1"
}

################### ECR ###################### 

resource "aws_ecr_repository" "test_franchise" {
  name = "test-franchise-ms"
}


################### VPC ############################ 


resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "Main VPC"
  }
}

resource "aws_subnet" "subnet_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "subnet_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
}

####################### INTERNET GATEWAY ###############

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

####################### ROUTE TABLE ###############

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "subnet_a_association" {
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "subnet_b_association" {
  subnet_id      = aws_subnet.subnet_b.id
  route_table_id = aws_route_table.public_rt.id
}



####################### SECURITY GROUP ###############

resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_groups  = [aws_security_group.alb_sg.id] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

########################## IAM ##############################


resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_rds_access_policy" {
  name = "ecs-rds-access-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "rds:DescribeDBInstances",
          "rds:Connect",
          "rds:ModifyDBInstance",
          "rds:CreateDBSnapshot",
          "rds:DeleteDBSnapshot",
          "rds:DescribeDBLogFiles",
          "rds:DownloadDBLogFilePortion"
        ],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}


######################## ALB ##################################

resource "aws_lb" "franchise_service_alb" {
  name               = "franchise-service-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.subnet_a.id,aws_subnet.subnet_b.id]

  depends_on = [aws_internet_gateway.igw, 
    aws_route_table_association.subnet_a_association, 
    aws_route_table_association.subnet_b_association,
    aws_security_group.alb_sg, 
    aws_subnet.subnet_a, 
    aws_subnet.subnet_b]
}


resource "aws_lb_target_group" "franchise_service_tg" {
  name     = "franchise-service-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  target_type = "ip"
  health_check {
    enabled             = true
    healthy_threshold   = 5
    unhealthy_threshold = 3
    timeout             = 120
    interval            = 121
    path                = "/actuator/health"
    matcher             = 200
  }

  depends_on = [aws_lb.franchise_service_alb]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.franchise_service_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.franchise_service_tg.arn
  }
  depends_on = [aws_lb_target_group.franchise_service_tg]
}

resource "aws_lb_listener_rule" "default_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.franchise_service_tg.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}


###################### ECS#################################

resource "aws_ecs_cluster" "ecs_franchise_cluster" {
  name = "franchise-cluster"
}

resource "aws_ecs_task_definition" "franchise_service_task" {
  family                   = "franchise-service-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name  = "franchise-service"
    image = "${aws_ecr_repository.test_franchise.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 8080
      hostPort      = 8080
    }]
    environment = [
      {
        name  = "DB_USERNAME"
        value = "test"
      },
      {
        name  = "DB_PASSWORD"
        value = "123456789"
      },
      {
        name  = "DB_HOST"
        value = "${aws_db_instance.franchise_rds.address}"
      },
      {
        name  = "DB_NAME"
        value = "franchisedb"
      },
      {
        name  = "DB_PORT"
        value = "5432"
      },
      {
        name  = "SCHEMA"
        value = "public"
      }
    ]
  }])

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn

  depends_on = [
    aws_iam_role.ecs_task_execution_role,
    aws_db_instance.franchise_rds
  ]
}

resource "aws_ecs_service" "franchise_ms_service" {
  name            = "franchise-ms-service"
  cluster         = aws_ecs_cluster.ecs_franchise_cluster.id
  task_definition = aws_ecs_task_definition.franchise_service_task.arn
  desired_count   = 1
  force_new_deployment = true
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true 
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.franchise_service_tg.arn
    container_name   = "franchise-service"
    container_port   = 8080
  }
  depends_on = [
    aws_lb_listener.http,
    aws_security_group.ecs_sg,
    aws_lb_target_group.franchise_service_tg,
    aws_iam_role.ecs_task_execution_role,
    aws_ecs_task_definition.franchise_service_task
  ]
}

####################### RDS ##############################


resource "aws_db_instance" "franchise_rds" {
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "16.2"
  instance_class       = "db.t3.micro"
  db_name              = "franchisedb"
  username             = "test"
  password             = "123456789"
  parameter_group_name = aws_db_parameter_group.franchise_rds_parameter_group.name
  skip_final_snapshot  = true
  publicly_accessible  = true
  multi_az             = false
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  db_subnet_group_name = aws_db_subnet_group.franchise_rds_subnet_group.name

  depends_on = [aws_vpc.main,aws_db_subnet_group.franchise_rds_subnet_group]
}

resource "aws_db_subnet_group" "franchise_rds_subnet_group" {
  name       = "franchise-rds-subnet-group"
  subnet_ids = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
}

resource "aws_security_group" "rds_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    #cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_parameter_group" "franchise_rds_parameter_group" {
  name        = "franchise-rds-parameter-group"
  family      = "postgres16"
  description = "Custom parameter group for franchise RDS"

  parameter {
    name  = "rds.force_ssl"
    value = "0"
  }
}

