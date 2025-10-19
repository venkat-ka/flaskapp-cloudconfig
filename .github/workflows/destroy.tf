name: Terraform Destroy AWS Resources

on:
  workflow_dispatch:   # runs only when you trigger manually in GitHub UI
  # OR uncomment next line to auto-destroy when a branch is deleted:
  # delete:

permissions:
  id-token: write
  contents: read

jobs:
  terraform-destroy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.9.8

      - name: Terraform Init
        run: terraform init

      - name: Terraform Destroy
        env:
          TF_VAR_ssh_public_key_b64: ${{ secrets.SSH_PUBLIC_KEY_B64 }}
        run: terraform destroy -auto-approve -input=false
