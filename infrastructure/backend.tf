terraform {
  backend "s3" {
    bucket = "mythicc-lightrag-tfstate"
    key    = "lightrag/terraform.tfstate"
    region = "ap-southeast-2"
    encrypt = true
  }
}
