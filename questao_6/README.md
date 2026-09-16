# Questao 6

## Prompt:

```
# Context
Equipe está atualizando as regras de segurança e todo módulo Terraform deverá seguir um novo formato.

# Action
Crie um módulo terraform para s3 que seja utilizado para armazenamento, esse arquivo será utilizado como template para criação de terraforms s3 para toda a empresa.


# Result
O módulo criado deve respeitar as seguintes regras

Tags obrigatórias em todo recurso: Owner, CostCenter, Environment.
Prefixo hvt- nos nomes de recursos.
Todo bucket S3 com: encryption habilitada (SSE-S3 mínimo), versioning ativo, block public access total, logging configurado.
Variáveis de entrada em variables.tf com description e type obrigatórios.


# Example
Siga o modelo abaixo de terraform

variable "environment" {
  description = "Nome do ambiente (dev, staging, production)"
  type        = string
}

locals {
  common_tags = {
    Owner       = var.owner
    CostCenter  = var.cost_center
    Environment = var.environment
  }
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block
  tags = merge(local.common_tags, {
    Name = "hvt-vpc-${var.environment}"
  })
}

```

## Modelo

Grok 4.5 Fast.

## Output:

Segue um módulo Terraform de S3 pronto para uso como template corporativo, alinhado às regras de segurança e ao padrão do exemplo.

Arquivos sugeridos: variables.tf, main.tf, outputs.tf (e opcionalmente versions.tf).

```
# variables.tf

variable "environment" {
  description = "Nome do ambiente (dev, staging, production)"
  type        = string
}

variable "owner" {
  description = "Responsável pelo recurso (time ou pessoa)"
  type        = string
}

variable "cost_center" {
  description = "Centro de custo para alocação financeira"
  type        = string
}

variable "bucket_name" {
  description = "Nome lógico do bucket (sem o prefixo hvt-). Será usado como hvt-<bucket_name>-<environment>"
  type        = string
}

variable "force_destroy" {
  description = "Se true, permite destruir o bucket mesmo com objetos (use com cautela)"
  type        = bool
  default     = false
}

variable "sse_algorithm" {
  description = "Algoritmo de criptografia do bucket. Mínimo: AES256 (SSE-S3). Alternativa: aws:kms"
  type        = string
  default     = "AES256"
}

variable "kms_master_key_id" {
  description = "ARN/ID da chave KMS quando sse_algorithm = aws:kms. Deixe null para SSE-S3"
  type        = string
  default     = null
}

variable "logging_target_bucket" {
  description = "Nome do bucket de destino dos access logs (já existente). Obrigatório para logging"
  type        = string
}

variable "logging_target_prefix" {
  description = "Prefixo (pasta) dentro do bucket de logs para os access logs deste bucket"
  type        = string
  default     = "s3-access-logs/"
}

variable "additional_tags" {
  description = "Tags extras opcionais mescladas às tags obrigatórias"
  type        = map(string)
  default     = {}
}
```

```
# main.tf

locals {
bucket_id = "hvt-${var.bucket_name}-${var.environment}"

common_tags = {
Owner = var.owner
CostCenter = var.cost_center
Environment = var.environment
}

tags = merge(local.common_tags, var.additional_tags)
}

resource "aws_s3_bucket" "this" {
bucket = local.bucket_id
force_destroy = var.force_destroy

tags = merge(local.tags, {
Name = local.bucket_id
})
}

resource "aws_s3_bucket_versioning" "this" {
bucket = aws_s3_bucket.this.id

versioning_configuration {
status = "Enabled"
}
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
bucket = aws_s3_bucket.this.id

rule {
apply_server_side_encryption_by_default {
sse_algorithm = var.sse_algorithm
kms_master_key_id = var.sse_algorithm == "aws:kms" ? var.kms_master_key_id : null
}
bucket_key_enabled = var.sse_algorithm == "aws:kms" ? true : null
}
}

resource "aws_s3_bucket_public_access_block" "this" {
bucket = aws_s3_bucket.this.id

block_public_acls = true
block_public_policy = true
ignore_public_acls = true
restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "this" {
bucket = aws_s3_bucket.this.id

target_bucket = var.logging_target_bucket
target_prefix = "${var.logging_target_prefix}${local.bucket_id}/"
}

# Opcional mas recomendado: ownership controls (BucketOwnerEnforced desativa ACLs)

resource "aws_s3_bucket_ownership_controls" "this" {
bucket = aws_s3_bucket.this.id

rule {
object_ownership = "BucketOwnerEnforced"
}
}

```

```

# outputs.tf

output "bucket_id" {
description = "Nome (id) do bucket S3 criado"
value = aws_s3_bucket.this.id
}

output "bucket_arn" {
description = "ARN do bucket S3 criado"
value = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
description = "Domain name regional do bucket"
value = aws_s3_bucket.this.bucket_regional_domain_name
}

output "bucket_region" {
description = "Região do bucket"
value = aws_s3_bucket.this.region
}

```

```
# versions.tf (recomendado)

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
```

```
module "app_storage" {
  source = "./modules/s3" # ou o path/registry interno da empresa

  environment           = "production"
  owner                 = "platform-team"
  cost_center           = "cc-1234"
  bucket_name           = "app-data"
  logging_target_bucket = "hvt-s3-access-logs-production"
  logging_target_prefix = "s3-access-logs/"

  additional_tags = {
    Application = "billing"
    ManagedBy   = "terraform"
  }
}
```

## Justificativa

O prompt segue a estrutura Context / Action / Result / Example: no Context foi informado que a equipe está padronizando módulos Terraform, já na Action foi solicitada a criação de um módulo S3 reutilizável como template corporativo. No Result foram definidas as regras obrigatórias e por fim no Example foi fornecido o padrão de código Terraform a seguir.
