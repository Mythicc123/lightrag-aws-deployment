# IAM Role for GitHub Actions OIDC
# Assumed by GitHub Actions workflows via aws-actions/configure-aws-credentials@v4
# using web-identity-token with audience sts.amazonaws.com.
# Allows the workflow to perform AWS API calls (e.g., describe instances)
# without storing long-lived AWS credentials.
# Role ARN is referenced in .github/workflows/deploy.yml

resource "aws_iam_role" "github_actions" {
  name = "mythicc123"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to the specific repository. Update 'Mythicc123/lightrag-aws-deployment'
            # if the repo name changes.
            "token.actions.githubusercontent.com:sub" = "repo:Mythicc123/lightrag-aws-deployment:*"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# Policy: allow read-only AWS access for the deploy workflow
resource "aws_iam_policy" "github_actions" {
  name        = "mythicc123-policy"
  description = "Read-only access for GitHub Actions CI/CD workflow"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.id
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role"
  value       = aws_iam_role.github_actions.arn
}
