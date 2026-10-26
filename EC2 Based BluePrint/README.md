# Deployment Week – CloudFormation Templates

One CloudFormation template per day of the AWS Deployment Blueprint, plus the Stage 3 stretch goal.
Each day builds only that day's AWS pieces; the stacks hand values to each other through parameters
and stack exports, so a team can stop at any day and still have a working system.

| File | Day | Stack name (suggested) | What it builds |
|---|---|---|---|
| `1-monday-ec2.yaml` | Monday | `matrix-monday` | EC2 (Ubuntu 24.04, m6a.large), Docker + Compose via UserData, IAM instance role for Secrets Manager, security group (22 / 80 / 443 / 3000 / 8080), Elastic IP |
| `2-tuesday-rds.yaml` | Tuesday | `matrix-tuesday` | RDS PostgreSQL, RDS security group (5432 from the EC2 SG only), Secrets Manager secret `matrix/production/credentials` |
| `3-wednesday-cdn.yaml` | Wednesday | `matrix-cdn` | Two private S3 buckets, Origin Access Control, CloudFront (`/` → Client, `/admin*` → Admin), bucket policies from Appendix A |
| `4-thursday-cdn-polish.yaml` | Thursday | `matrix-cdn` (**update**) | Wednesday's stack plus the SPA deep-link refresh fix |
| `5-stage3-fargate.yaml` | Stage 3 | `matrix-stage3` | ECR, ECS cluster, Service Connect, Kafka / auth / orders on Fargate, ALB on 3000 and 8080, RDS rule for the tasks |

All templates take a `ProjectName` parameter (default `matrix`). If several teams share one AWS
account, give each team its own value so names and exports don't collide.

---

## Monday

```bash
aws cloudformation deploy --stack-name matrix-monday \
  --template-file 1-monday-ec2.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides KeyName=my-key MyIpCidr=$(curl -s https://checkip.amazonaws.com)/32 \
                        VpcId=vpc-xxxx SubnetId=subnet-xxxx
```

Optional: add `GitRepoUrl=https://github.com/...` (public repo) and the instance clones it and runs
`docker compose up -d` on first boot. Otherwise SSH in (`ubuntu@<PublicIp>`) and clone by hand.
Docker install takes 2–3 minutes after the instance is up; it's done when
`/var/log/matrix-bootstrap.done` exists.

**Resizing (the "resize, don't rebuild" pitfall):** re-run the same command with
`InstanceType=m6a.xlarge`. CloudFormation stops, resizes and restarts the instance; the Elastic IP
keeps the address the same.

## Tuesday

```bash
aws cloudformation deploy --stack-name matrix-tuesday \
  --template-file 2-tuesday-rds.yaml \
  --parameter-overrides VpcId=vpc-xxxx DbSubnetIds=subnet-aaaa,subnet-bbbb \
                        Ec2SecurityGroupId=<Monday output Ec2SecurityGroupId> \
                        JwtSharedSecret=$(openssl rand -hex 32)
```

About 10 minutes. The DB password is generated into the secret automatically.

**Manual step – migrate the data** (on the EC2 instance; using the Postgres image avoids a
pg_dump/server version mismatch). Get the password from the secret, then:

```bash
DB_PASS=$(aws secretsmanager get-secret-value --secret-id matrix/production/credentials \
          --query SecretString --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["DB_PASSWORD"])')
docker compose exec -T db pg_dump -U <local-user> <local-db> \
  | docker run -i --rm -e PGPASSWORD="$DB_PASS" postgres:16 \
      psql -h <DbEndpoint> -U postgres_admin -d orders_db
```

Then change the DB host in `docker-compose.yml` to `DbEndpoint` and remove the `db` service.

## Wednesday

```bash
aws cloudformation deploy --stack-name matrix-cdn --template-file 3-wednesday-cdn.yaml
```

**Manual steps:** set the Angular env files to the Monday `AuthApiUrl` / `OrdersApiUrl`, build, then
upload (exact commands are in the stack Outputs):

```bash
aws s3 sync dist/<client-app>/browser s3://<ClientBucketName>/ --delete
aws s3 sync dist/<admin-app>/browser  s3://<AdminBucketName>/admin/ --delete   # note the admin/ prefix
```

Add `http://<distribution>.cloudfront.net` to the backend CORS allow-list.

## Thursday

Same stack name — this is an update of Wednesday's stack:

```bash
aws cloudformation deploy --stack-name matrix-cdn --template-file 4-thursday-cdn-polish.yaml
```

Then refresh `http://<distribution>/admin/dashboard` – it should load the Admin app.

## Stage 3 (stretch)

Two passes, because Fargate can only start once the images are in ECR:

```bash
# Pass 1: everything, apps at 0 tasks
aws cloudformation deploy --stack-name matrix-stage3 \
  --template-file 5-stage3-fargate.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides VpcId=vpc-xxxx PublicSubnetIds=subnet-aaaa,subnet-bbbb

# push both images to the repo URIs in the Outputs (Apple Silicon: --platform linux/amd64)

# Pass 2: start the apps
aws cloudformation deploy --stack-name matrix-stage3 \
  --template-file 5-stage3-fargate.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides AppDesiredCount=1
```

Then point the Angular env files at the `AuthApiUrl` / `OrdersApiUrl` outputs, rebuild, upload,
and invalidate CloudFront.

**Decommissioning the EC2 instance (Step 8), CloudFormation version – after the demo:**

1. `aws cloudformation deploy --stack-name matrix-tuesday --template-file 2-tuesday-rds.yaml --parameter-overrides Ec2SecurityGroupId=""` – removes the EC2 → RDS rule.
2. `aws cloudformation delete-stack --stack-name matrix-monday` – terminates the instance, deletes its disk, releases the Elastic IP, and removes the security group and IAM role in one go.

(Before the demo, stopping the instance from the console is still the reversible step.)

---

## Changes from the blueprint, and why

These are things the blueprint, followed literally, would break. Worth a look before class.

1. **Mixed content (Wednesday).** CloudFront serves over HTTPS by default, but the Angular apps call
   the APIs at `http://<ip>:3000` / `:8080`. Browsers block http calls from an https page, so logins
   would silently fail. The templates use `ViewerProtocolPolicy: allow-all` and students must open the
   site with **http://**. The real fix is TLS on the APIs (the ALB + ACM in Appendix C).
2. **Admin files need the `admin/` prefix (Wednesday).** CloudFront forwards the full path, so
   `/admin/main.js` is read from the object key `admin/main.js` in the Admin bucket. Uploading the
   build to the bucket root gives 403s.
3. **SPA refresh fix (Thursday).** Custom error responses apply to the whole distribution, so
   refreshing `/admin/dashboard` would return the *Client* app's `index.html`. Thursday uses a small
   CloudFront Function instead that sends `/admin/*` routes to `/admin/index.html` and everything else
   to `/index.html`. (Tested: `/`, `/login`, `/admin`, `/admin/dashboard`, and static files all route
   correctly.)
4. **IMDS hop limit (Monday).** With IMDSv2 and the default hop limit of 1, the AWS SDK running
   *inside a Docker container* can't get the instance role's credentials, so Tuesday's Secrets
   Manager call fails. The template sets the hop limit to 2.
5. **Elastic IP (Monday).** Stopping the instance to resize (pitfall #1) gives it a new public IP,
   which breaks every Angular env file. The Elastic IP keeps it stable.
6. **Docker repo line (Monday step 2).** The blueprint escapes `\$(dpkg --print-architecture)`, so a
   literal `$(dpkg ...)` ends up in the apt source and `apt-get update` fails. The UserData uses the
   unescaped form from docs.docker.com.
7. **Kafka on Fargate (Stage 3).** The Kafka service deploys with min 0% / max 100% so a redeploy
   never runs two brokers with the same node ID at once.

Smaller things: the IAM role names are prefixed with `ProjectName` (IAM names are account-wide),
the role also gets `AmazonSSMManagedInstanceCore` so Session Manager works if SSH gets locked out,
and the RDS stack takes a final snapshot if deleted.
