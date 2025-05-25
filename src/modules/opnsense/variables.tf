variable "node_name" {
    type=string
}

variable "node_endpoint" {
    type=string
    }

variable "api_token" {
    type=string
    sensitive = true
}

variable "admin_username" {
    type = string
}

variable "admin_password" {
    type = string
    sensitive = true
}