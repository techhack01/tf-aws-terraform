terraform {
  backend "s3" {
    bucket         = "raj-tf-state-bucket"
    key            = "terraform/state"
    region         = "us-east-1"
    encrypt        = true
  }
}
