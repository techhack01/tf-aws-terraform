terraform {
  required_version = ">= 0.11.0"
}

terraform { 
  cloud { 
    
    organization = "aws-ia2" 

    workspaces { 
      name = "tf-aws-terraform" 
    } 
  } 
}

provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_instance" "ubuntu" {
  ami           = "${var.ami_id}"
  instance_type = "${var.instance_type}"
  availability_zone = "${var.aws_region}a"

}
