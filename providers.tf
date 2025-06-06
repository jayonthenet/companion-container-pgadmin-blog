terraform {
  required_providers {
    humanitec = {
      source  = "humanitec/humanitec"
      version = "~> 1.0"
    }
    terracurl = {
      source = "devops-rob/terracurl"
    }
  }
  required_version = ">= 1.3.0"
}
