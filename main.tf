locals {
  s3_domain_name = "${var.local_prefix}.sctp-sandbox.com"
}

resource "aws_s3_bucket" "s3_bucket" {
  bucket = local.s3_domain_name
  force_destroy = true
}

# Block public access to the S3 bucket
resource "aws_s3_bucket_public_access_block" "s3_block" {
  bucket = aws_s3_bucket.s3_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

## Creates a VPC resource with 1 Private Subnets
resource "aws_vpc" "s3_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "${var.local_prefix}"
  }
}

## Creates the first private subnet in AZ1
resource "aws_subnet" "my_private_subnet_az1" {
  vpc_id     = aws_vpc.s3_vpc.id
  cidr_block = "10.0.128.0/20"
  availability_zone = "us-east-1a"

  tags = {
    Name = "${var.local_prefix}-private-subnet-az1"
  }
}

## Creates an IGW for your VPC
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.s3_vpc.id

  tags = {
    Name = "${var.local_prefix}-tf-igw"
  }
}

## Creates a private route table for az1
resource "aws_route_table" "my_private_route_table_az1" {
  vpc_id = aws_vpc.s3_vpc.id

  route {
    cidr_block = aws_vpc.s3_vpc.cidr_block
    gateway_id = "local"
  }

  tags = {
    Name = "${var.local_prefix}-tf-private-rtb-az1"
  }

}

## Associate private route table to the private subnets accordingly
resource "aws_route_table_association" "first_private_assoc" {
  subnet_id      = aws_subnet.my_private_subnet_az1.id
  route_table_id = aws_route_table.my_private_route_table_az1.id
}

# Create a VPC Endpoint for S3 access
resource "aws_vpc_endpoint" "s3_vpce" {
  vpc_id       = aws_vpc.s3_vpc.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [aws_route_table.my_private_route_table_az1.id]
}

# Attach a bucket policy allowing access via VPC Endpoint and Cloudfront interaction
resource "aws_s3_bucket_policy" "s3_policy" {
  bucket = aws_s3_bucket.s3_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowVPCAccess"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.s3_bucket.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceVpc" = aws_vpc.s3_vpc.id }
        }
      },
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { "Service": "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.s3_bucket.arn}/*"
        Condition = {
          StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.cloudfront.arn }
        }
      }
    ]
  })
}

# IAM Role for accessing S3
resource "aws_iam_role" "s3_access_role" {
  name = "${var.local_prefix}-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}


# IAM Policy for the role to access S3
resource "aws_iam_policy" "s3_access_policy" {
  name        = "${var.local_prefix}-s3-policy"
  description = "IAM Policy for accessing private S3 bucket"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.s3_bucket.arn}", "${aws_s3_bucket.s3_bucket.arn}/*"]
      }
    ]
  })
}


# Attach the policy to the IAM role
resource "aws_iam_role_policy_attachment" "s3_role_attach" {
  role       = aws_iam_role.s3_access_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

resource "aws_security_group" "vpc_security" {
  name   = var.sec_group_name
  vpc_id = aws_vpc.s3_vpc.id # var.vpc_id
    ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}


resource "aws_acm_certificate" "cert" {
  domain_name       = local.s3_domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.local_prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cloudfront" {
  origin {
    domain_name              = aws_s3_bucket.s3_bucket.bucket_regional_domain_name
    origin_id                = aws_s3_bucket.s3_bucket.id
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [local.s3_domain_name]

  web_acl_id = aws_wafv2_web_acl.waf_acl.arn

  default_cache_behavior {
    target_origin_id       = aws_s3_bucket.s3_bucket.id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    cache_policy_id  = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS Managed CachingOptimized
    compress = true

  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Description = "CGPT TF CFS3"
  }

}

resource "aws_wafv2_web_acl" "waf_acl" {
  name        = "${var.local_prefix}-waf"
  scope       = "CLOUDFRONT"
  description = "WAF for ${var.local_prefix}"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.local_prefix}-waf"
    sampled_requests_enabled   = true
  }
 }

resource "aws_route53_record" "dns_record" {
  zone_id = data.aws_route53_zone.sctp_zone.zone_id
  name    = local.s3_domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cloudfront.domain_name
    zone_id                = aws_cloudfront_distribution.cloudfront.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "null_resource" "clone_git_repo" {
  provisioner "local-exec" {
    command = <<EOT
      git clone https://github.com/cloudacademy/static-website-example website_content
      aws s3 sync website_content s3://${aws_s3_bucket.s3_bucket.id} --exclude "*.MD" --exclude ".git*" --delete 
    EOT
  }
  
  # Ensures this runs after the S3 bucket is created
  depends_on = [aws_s3_bucket.s3_bucket]
}

output "vpc_id" {
  value = aws_vpc.s3_vpc.id
}