resource "aws_s3_bucket" "test_bucket" {
  bucket = "amr-terraform-test-bucket"
  force_destroy = true
}