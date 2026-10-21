#AWS Setup

Materials for the Hello World Wealth / PaySprint Wealth AWS lab: how the class AWS account is set up, how each service is built by hand, and the Jenkins pipeline that deploys student apps.

## Contents

```
Amazon Setup/
├── Lab Setup Guides/
│   └── Sprint 11 AWS Lab Setup .pages
├── AWS Setup Guides/
│   ├── AWS_Docker_ECR_ECS_Setup.pdf
│   ├── AWS_Angular_S3_CloudFront_Setup_Guide.pdf
│   ├── AWS_ALB_Setup_Guide.docx
│   ├── AWS_RDS_VPC_Setup.docx
│   └── Loading SQL with CloudShell.pdf
└── Example Jenkins/
    ├── Jenkins-Shared.yaml
    └── Jenkinsfile.aws
```

## Lab Setup Guides

| File | What it is |
|---|---|
| `Sprint 11 AWS Lab Setup .pages` | One-page class handout (Apple Pages). Gives the AWS sign-in URL, account alias, the shared `student` bootstrap user, the default region (us-east-1) and the `students` IAM group. Each student signs in as `student`, creates their own IAM user, adds it to `students`, then signs back in as themselves. Contains the sign-in URL, so share it with the class only. |

## AWS Setup Guides

Student-facing, console-based walkthroughs. Each service is built by hand in the AWS console, using `hww-*` resource names.

| File | Covers |
|---|---|
| `AWS_Docker_ECR_ECS_Setup.pdf` (7 pp.) | Choosing a region, AWS CLI and CloudShell, creating an ECR repository, pushing a Docker Desktop image, creating an ECS Fargate cluster, registering a task definition, running and verifying the service, and deploying the other services. Ends with student success criteria. |
| `AWS_Angular_S3_CloudFront_Setup_Guide.pdf` (4 pp.) | Building an Angular app for production, uploading it to a private S3 bucket, serving it through CloudFront with Origin Access Control, SPA routing fallback, verifying the site, and updating a deployment. For both the client and reporting apps. |
| `AWS_ALB_Setup_Guide.docx` | Creating the ALB security group, target groups (orders, auth, holdings), the Application Load Balancer, path-based listener rules (`/api/orders/*`, `/api/auth/*`, `/api/holdings/*`), and connecting an existing ECS service to its target group. |
| `AWS_RDS_VPC_Setup.docx` | Creating a team VPC, security groups, and a private RDS PostgreSQL instance; connecting from a CloudShell VPC environment; creating the database and loading the enterprise schema; troubleshooting; completion checklist and cleanup. |
| `Loading SQL with CloudShell.pdf` (5 pp.) | Instructor procedure for loading SQL into a team's database that was deployed by the `leap-<team>` CloudFormation stack: find the subnet and security group, create the CloudShell VPC environment, bring in the script and SQL files, run the script, verify, troubleshoot, and clean up. |

## Example Jenkins

| File | What it is |
|---|---|
| `Jenkins-Shared.yaml` | CloudFormation template for the shared, instructor-managed Jenkins controller: its own VPC (10.90.0.0/16), one public subnet, a security group open on ports 22 and 8080 to the instructor's IP only, an EC2 instance (Java, Docker, Maven, Node, AWS CLI, Jenkins) and the `hww-jenkins-controller-role` instance role that may assume the team deploy roles. Outputs the Jenkins URL and role ARN. |
| `Jenkinsfile.aws` | Example per-team Jenkins pipeline, pre-filled for team5 (ca-central-1). Stages: Checkout, Inspect tools, Validate AWS credentials, Build Docker images, Build Angular applications, Publish images and Angular files, Instructor approval, Deploy to ECS, Backend health checks, Route checks (CloudFront to ALB to service). Change the values in the `environment` block for each team. |

## Suggested reading order

1. `Sprint 11 AWS Lab Setup .pages`: account and sign-in.
2. `AWS_Docker_ECR_ECS_Setup.pdf`: containers on ECS.
3. `AWS_ALB_Setup_Guide.docx`: load balancer and API routing.
4. `AWS_Angular_S3_CloudFront_Setup_Guide.pdf`: front ends.
5. `AWS_RDS_VPC_Setup.docx`: database.
6. `Jenkins-Shared.yaml`, then `Jenkinsfile.aws`: automated deployment.
7. `Loading SQL with CloudShell.pdf`: loading data into a team database (instructor).

## Not in this folder

The `leap-team` CloudFormation template that the Jenkinsfile and the SQL-loading guide refer to, and the `run-sql.sh` script, are not included here.
