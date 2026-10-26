# 🗺️ Your AWS Deployment Blueprint

This document is your guide for deployment week. It describes the target architecture you are
building, explains why it is shaped the way it is, and then walks through a day-by-day plan to
get there. Read the whole thing once before Monday, then come back to the relevant day's section
as you work.

The approach is deliberately pragmatic. You start by lifting your existing Docker setup onto a
single EC2 instance so you have something working in the cloud on Day 1. Each day after that you
pull one piece out of Docker and move it to a native AWS service. At every point you have a
working fallback.

---

### 1. The Target Architecture ("End Result")

```text
                           [ User Browser ]
                             │          │
        ┌────────────────────┘          └────────────────────┐
        ▼ (UI Static Assets via CDN)                         ▼ (API Requests via CORS)
┌───────────────────────┐                        ┌────────────────────────────────────────┐
│    AWS CLOUDFRONT     │                        │          AWS EC2 INSTANCE (m6a.large)  │
│ (d12345xyz.cloudfront.net)             │                                        │
└───────────┬───────────┘                        │  ┌──────────────────┐  ┌────────────┐  │
            │                                    │  │   Node.js Auth   │  │Spring Boot │  │
   ┌────────┴────────┐                           │  │  Service (3000)  │  │Orders (8080)  │
   ▼                 ▼                           │  └────────┬─────────┘  └──────┬─────┘  │
┌─────────────┐   ┌─────────────┐                │           │                   │        │
│AWS S3 BUCKET│   │AWS S3 BUCKET│                │           ▼                   ▼        │
│  (Client)   │   │   (Admin)   │                │  ┌──────────────────────────────────┐  │
└─────────────┘   └─────────────┘                │  │     Apache Kafka (Local Pod)     │  │
                                                 │  └──────────────────────────────────┘  │
                                                 └───────────────────┬────────────────────┘
                                                                     │
                                                                     ▼ (Secure Port 5432)
                                                 ┌────────────────────────────────────────┐
                                                 │      AMAZON AURORA / RDS POSTGRES      │
                                                 └────────────────────────────────────────┘
```

This is the end state of the four-day plan. The optional **Stage 3** section, which follows the
day-by-day plan, goes one step further and replaces the EC2 instance with ECS Fargate.

---

### 2. How the Routing Works

#### Layer 1: The CloudFront Edge
CloudFront sits in front of your static user interfaces and serves them from AWS's global edge
network:
*   **Paths `/` and `/admin*`:** Routed to their respective private S3 buckets (Client UI and
    Admin UI).
*   **Dynamic API traffic:** Does *not* go through CloudFront. Your Angular apps call the backend
    APIs directly from the browser, using CORS, targeting specific ports on your EC2 instance.

#### Layer 2: The Backend on EC2
*   **Kafka Broker:** Runs inside Docker on the same EC2 instance as your services. The Node.js
    and Spring Boot services talk to it over `localhost:9092`, so there is no cross-instance
    networking to configure.
*   **Database:** The Node.js and Spring Boot services connect out to your Amazon RDS PostgreSQL
    instance over **port 5432**. The database is locked down so that only your EC2 instance can
    reach it.

---

### 3. Why Everything Runs on One EC2 Instance

By keeping your microservices and Kafka together on a single `m6a.large` (or `m6a.xlarge`)
instance, you only have to manage security groups and host networking for **one compute target**.
You still get the real architectural benefits of microservices, message streaming, and a managed
data layer, without spending your four days wiring together several separate servers. The
production-grade alternative is described in Appendix C so you understand what you are trading
off, and Stage 3 lets you build a large part of it if you finish early.

---

### 4. The Week at a Glance

```text
 Monday AM           Tuesday             Wednesday           Thursday            Friday AM
 ┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐
 │ Code & EC2    │   │ Setup S3 &    │   │ Connect S3    │   │ Final Testing │   │ Live Demo &   │
 │ Local Build   │►  │ RDS Postgres  │►  │ & CloudFront  │►  │ & Presentation│►  │ Presentations │
 └───────────────┘   └───────────────┘   └───────────────┘   └───────────────┘   └───────────────┘
```

If you get ahead of this schedule, the **Stage 3** section that follows the day-by-day plan
walks through moving your containers off the EC2 instance onto ECS Fargate and then switching the
instance off for good.

---

# 🚀 The 4-Day Migration Plan

### 🟩 MONDAY: The Docker "Lift & Shift" Baseline
**Goal:** Prove the full application runs identically in the cloud as it does on your laptop.

```text
                           [ User Browser ]
                                  │
                                  ▼ (Hit Public IP on Ports 80, 3000, 8080)
                       ┌────────────────────────────────────────┐
                       │          AWS EC2 INSTANCE (m6a.large)  │
                       │                                        │
                       │  ┌──────────────────┐  ┌────────────┐  │
                       │  │ Static Angular   │  │ Static UI  │  │
                       │  │ Client (Port 80) │  │   Admin    │  │
                       │  └──────────────────┘  └────────────┘  │
                       │  ┌──────────────────┐  ┌────────────┐  │
                       │  │   Node.js Auth   │  │Spring Boot │  │
                       │  │  Service (3000)  │  │Orders (8080)  │
                       │  └────────┬─────────┘  └──────┬─────┘  │
                       │           │                   │        │
                       │           ▼                   ▼        │
                       │  ┌──────────────────────────────────┐  │
                       │  │     Apache Kafka (Local Pod)     │  │
                       │  └────────────────┬─────────────────┘  │
                       │                   │                    │
                       │                   ▼                    │
                       │  ┌──────────────────────────────────┐  │
                       │  │    PostgreSQL DB (Local Pod)     │  │
                       │  └──────────────────────────────────┘  │
                       └────────────────────────────────────────┘
```

1. **Provision Compute & Identity:** Launch one **m6a.large** instance (Ubuntu 24.04 LTS
   recommended, or Amazon Linux 2023).
   * **IAM Instance Profile:** Create an IAM Role named `MatrixInstanceSecretsReaderRole`. Attach
     an inline policy allowing `secretsmanager:GetSecretValue`. You will not create the secret
     itself until Tuesday, so use a wildcard resource so the role is ready in advance:
     `arn:aws:secretsmanager:*:*:secret:matrix/production/*`. Attach this role to your EC2
     instance.
   * Attach a custom **Security Group** allowing inbound **SSH (port 22)** from your own IP only,
     and **HTTP (port 80)**, **HTTPS (port 443)**, **port 3000**, and **port 8080** from
     **Anywhere (0.0.0.0/0)**. See Appendix B for a fuller explanation of security groups.

2. **Install Docker & Compose:** SSH into your instance using the correct username (`ubuntu` for
   Ubuntu, `ec2-user` for Amazon Linux) and follow the official Docker Engine installation steps
   (also documented at `docs.docker.com`):

   **For Ubuntu instances:**
   ```bash
   # Add Docker's official GPG key:
   sudo apt-get update
   sudo apt-get install -y ca-certificates curl
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc

   # Add the repository to Apt sources:
   echo \
     "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
     $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
     sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

   sudo apt-get update

   # Install the official Docker packages:
   sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

   **For Amazon Linux 2023 instances:**
   ```bash
   # Set up the official Docker repository:
   sudo dnf install -y dnf-plugins-core
   sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

   # Install official Docker Engine packages:
   sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

   # Start and enable the service:
   sudo systemctl enable --now docker
   ```

3. **Deploy the Stack:** Clone your git repositories onto the instance, change into the folder
   containing your compose file, and start everything:
   ```bash
   sudo docker compose up -d
   ```
4. **Milestone Check:** Open a browser and hit your EC2 public IP on ports 3000 and 8080. If
   your Node Auth API and Spring Boot Orders API both respond over the public internet, Monday
   is done.

---

### 🟨 TUESDAY: Stage 1 Migration — The Managed Database
**Goal:** Move your data out of Docker and onto a managed AWS database.

```text
                           [ User Browser ]
                                  │
                                  ▼ (Hit Public IP on Ports 80, 3000, 8080)
                       ┌────────────────────────────────────────┐
                       │          AWS EC2 INSTANCE (m6a.large)  │
                       │                                        │
                       │  ┌──────────────────┐  ┌────────────┐  │
                       │  │ Static Angular   │  │ Static UI  │  │
                       │  │ Client (Port 80) │  │   Admin    │  │
                       │  └──────────────────┘  └────────────┘  │
                       │  ┌──────────────────┐  ┌────────────┐  │
                       │  │   Node.js Auth   │  │Spring Boot │  │
                       │  │  Service (3000)  │  │Orders (8080)  │
                       │  └────────┬─────────┘  └──────┬─────┘  │
                       │           │                   │        │
                       │           ▼                   ▼        │
                       │  ┌──────────────────────────────────┐  │
                       │  │     Apache Kafka (Local Pod)     │  │
                       │  └──────────────────────────────────┘  │
                       └───────────────────┬────────────────────┘
                                           │
                                           ▼ (Secure Connection on Port 5432)
                       ┌────────────────────────────────────────┐
                       │      AMAZON AURORA / RDS POSTGRES      │
                       └────────────────────────────────────────┘
```

1. **Spin up RDS:** Provision an **Amazon RDS PostgreSQL** instance (`db.t3.micro` or
   `db.t3.small` to keep costs down).
2. **Isolate the Database Network:** Edit the RDS security group to allow inbound
   **PostgreSQL (port 5432)**, but set the source to your **EC2 instance's security group ID**
   rather than an IP range. This means only code running on your EC2 instance can reach the
   database.
3. **Migrate the Data:** Run `pg_dump` against your Monday Docker Postgres container and pipe the
   schema and data into your new RDS endpoint.
4. **The Swap:** Edit your environment files or `docker-compose.yml` on the EC2 instance. Change
   the database host from `localhost` or `db` to your RDS endpoint.
5. **Milestone Check:** Stop and remove the local Docker Postgres container, then run
   `sudo docker compose up -d`. If your backend APIs still read and write data correctly, the
   database migration is complete.

#### 🔐 Tuesday Security Enhancement: Secrets Manager
Rather than hardcoding database credentials or your `JWT_SHARED_SECRET` in environment files,
store them in AWS Secrets Manager and have your services fetch them at startup using the IAM role
you attached on Monday.

1. **Create the Secret:** Create a new secret named `matrix/production/credentials` using the
   Key/Value pair template.
2. **Populate it:**
   * `DB_PASSWORD` -> (a strong, random password)
   * `JWT_SHARED_SECRET` -> (a 256-bit cryptographically secure string)
   * `DB_USERNAME` -> `postgres_admin`
   * `DB_NAME` -> `orders_db`
3. **Read it from code:** Use the official AWS SDK in each backend service to fetch
   `matrix/production/credentials` during startup, before the application routes come up. No
   access keys are needed in your code: the SDK picks up the instance role automatically.

---

### 🟧 WEDNESDAY: Stage 2 Migration — CDN Edge & S3 Storage
**Goal:** Pull the Angular UIs out of Docker, serve them from S3 via CloudFront, and have the
browser call your EC2 APIs directly using CORS.

1. **Create the Storage:** Create **two separate S3 buckets**: one for the Client UI and one for
   the Admin UI.
   * Leave **"Block *all* public access"** checked. The buckets stay private; CloudFront will be
     granted access through a bucket policy in step 4 and Appendix A.
   * You do **not** need to enable static website hosting. CloudFront reads the buckets through
     their standard REST endpoints.
2. **The Direct CORS Strategy:** Your frontends will call the EC2 instance directly over the
   public internet rather than going through a load balancer. Before you build, open your Angular
   environment files and point the API endpoints at your server:
   * `AUTH_API_URL` -> `http://your-ec2-public-ip:3000`
   * `ORDERS_API_URL` -> `http://your-ec2-public-ip:8080`
3. **Compile and Upload:**
   * Compile the Client UI (`ng build`) and upload the production files to Bucket 1.
   * **Important:** Compile the Admin UI for a sub-path using the exact command in Appendix A
     (`--base-href=/admin/ --deploy-url=/admin/`). Upload those files to Bucket 2.
4. **Create the CloudFront Distribution:**
   * **Origins:** Add both S3 buckets as origins, selecting the REST endpoint names the AWS
     dropdown suggests (e.g. `bucket-name.s3.amazonaws.com`).
   * **Origin Access Control (OAC):** Set origin access to **Origin Access Control settings
     (recommended)** and click "Create control setting". This lets CloudFront authenticate to
     your private buckets while they stay closed to the public internet.
   * **Default Root Object:** In the General settings, set the **Default Root Object** to
     `index.html`.
   * **Bucket Policies:** After the distribution is created, apply the bucket policy in
     Appendix A to *both* buckets. Until you do, CloudFront will return 403 Forbidden.

> ⚠️ **LAB SHORTCUT: RAW IP EXPOSURE & INSECURE API ENDPOINTS**
> **Severity: Medium (Security Architecture Flaw)**
> By skipping an inner load balancer and using client-side CORS, your microservices expose their
> raw EC2 public IP and ports (`3000` and `8080`) directly to the internet.
> * **Why we take this shortcut:** It avoids the cost of an Application Load Balancer and the
>   setup time for target groups, which matters on a four-day timeline.
> * **How production does it:** Backend servers live in private subnets with no direct internet
>   access. All traffic routes through an API Gateway or an ALB paired with AWS WAF, over HTTPS
>   with certificates managed by ACM. See Appendix C.

---

### 🟥 THURSDAY: The "Lock & Polish" Phase
**Goal:** Lock down configuration, run end-to-end tests, and freeze the build ready for Friday's
demo.

1. **End-to-End Testing:** Use your application through your CloudFront address only
   (e.g. `d12345xyz.cloudfront.net`). Check that logging in via `/` works, the admin panel at
   `/admin` works, and data flows end to end with Kafka processing in the background.
2. **Fix the Single-Page Application (SPA) Refresh Bug:**
   Angular handles routing in JavaScript, so pressing Refresh on a deep path such as
   `/admin/dashboard` makes CloudFront look for a folder that does not exist in S3 and return an
   error. Tell CloudFront to serve `index.html` instead:
   * Open the **CloudFront console** and click your distribution.
   * Open the **Error responses** tab and click **Create custom error response**.
   * Set **HTTP error code** to `403: Forbidden`.
   * Set **Customize error response** to `Yes`.
   * Set **Response page path** to `/index.html`.
   * Set **HTTP Response code** to `200: OK`.
   * Click **Create**. Repeat the same steps for `404: Not Found`.
3. **Code Freeze:** Once the two steps above pass, and by noon at the latest, stop making
   infrastructure and code changes. Spend the afternoon on your presentation.

---

### 🚨 3 Pitfalls to Avoid This Week

* **Running out of memory? Resize, don't rebuild.** If your containers start lagging or throw
  Out-Of-Memory errors (JVM heap is the usual culprit), do not recreate the machine. Stop the EC2
  instance, change the instance type to **m6a.xlarge** (4 vCPUs, 16GB RAM, same disk), and start
  it again. It takes about three minutes.
* **The CloudFront Caching Trap:** If you upload a frontend fix to S3 and your browser still shows
  the old version, CloudFront is serving a cached copy from the edge. In the CloudFront console,
  select your distribution, open the **Invalidations** tab, and create an invalidation for `/*`.
* **Leave Kafka Alone:** Do not try to migrate Kafka to AWS MSK (Managed Streaming for Kafka). It
  needs significant network configuration and will consume your whole timeline. Running Kafka in
  Docker on your EC2 instance is a perfectly valid choice for this architecture. (If you move to
  Fargate in Stage 3, Kafka moves as a container too, still not to MSK.)

---

# 🟦 STAGE 3 (Stretch Goal): ECS Fargate & Decommissioning the EC2 Instance

**Goal:** Move your three containers (Node Auth, Spring Boot Orders, Kafka) off the single EC2
instance and onto **Amazon ECS running on Fargate**, so AWS manages the servers for you. Once the
Fargate services are proven, switch off and terminate the EC2 instance.

Only start this once Thursday's end-to-end test passes through CloudFront. Everything here is
additive: your EC2 instance keeps running until the very last step, so you always have a working
fallback for Friday's demo.

### Why Fargate?
On EC2 you own the operating system: Docker upgrades, disk space, security patches, and what
happens when the box reboots. With Fargate you hand ECS a **task definition** (which image, how
much CPU and memory, which ports, which environment variables) and ECS runs it, restarts it if it
crashes, and never shows you a server. It is the same containers you already have, with the host
removed.

### The Stage 3 Architecture

```text
                           [ User Browser ]
                             │          │
        ┌────────────────────┘          └────────────────────┐
        ▼ (UI Static Assets via CDN)                         ▼ (API Requests via CORS)
┌───────────────────────┐                        ┌────────────────────────────────────────┐
│    AWS CLOUDFRONT     │                        │   APPLICATION LOAD BALANCER (ALB)      │
│ (d12345xyz.cloudfront.net)             │   Listeners: :3000 and :8080           │
└───────────┬───────────┘                        └───────────┬───────────────┬────────────┘
            │                                                │               │
   ┌────────┴────────┐                                       ▼               ▼
   ▼                 ▼                        ┌──────────────────────────────────────────────┐
┌─────────────┐   ┌─────────────┐             │             ECS CLUSTER (FARGATE)            │
│AWS S3 BUCKET│   │AWS S3 BUCKET│             │                                              │
│  (Client)   │   │   (Admin)   │             │  ┌────────────────┐   ┌──────────────────┐   │
└─────────────┘   └─────────────┘             │  │ auth-service   │   │ orders-service   │   │
                                              │  │ (Fargate task) │   │ (Fargate task)   │   │
                                              │  └───────┬────────┘   └────────┬─────────┘   │
                                              │          │  kafka:9092         │             │
                                              │          ▼  (Service Connect)  ▼             │
                                              │  ┌──────────────────────────────────────┐    │
                                              │  │      kafka (Fargate task, KRaft)     │    │
                                              │  └──────────────────────────────────────┘    │
                                              └───────────────────────┬──────────────────────┘
                                                                      │
                                                                      ▼ (Port 5432)
                                              ┌──────────────────────────────────────────────┐
                                              │         AMAZON AURORA / RDS POSTGRES         │
                                              └──────────────────────────────────────────────┘

                   ┌────────────────────────────────────────┐
                   │   AWS EC2 INSTANCE (m6a.large)         │  <-- TERMINATED at the end of Stage 3
                   └────────────────────────────────────────┘
```

Two things change compared with the EC2 design, and both are forced on you by Fargate:

* **An ALB appears.** A Fargate task gets a *new* IP address every time it restarts or redeploys,
  so you can no longer hardcode an IP into your Angular environment files. The ALB gives you one
  stable DNS name. This is the one place in the project where you accept the ALB's hourly cost;
  Appendix C explains why it is the right production shape anyway.
* **Kafka becomes a service with a DNS name.** Your services used to reach Kafka on `localhost`.
  On Fargate each task is its own networking island, so Kafka runs as a separate ECS service and
  the other two find it by name (`kafka:9092`) via **ECS Service Connect**.

---

### Step 1: Push Your Images to Amazon ECR

Fargate cannot build images; it can only pull them. Push your two application images to
**Amazon Elastic Container Registry (ECR)**. Kafka uses a public image and needs no repository.

1. In the **ECR console**, create two private repositories: `matrix/auth-service` and
   `matrix/orders-service`.
2. Click a repository and press **View push commands**. They are four commands: log in, build,
   tag, push. Run them from the folder containing each service's Dockerfile.
3. **If you are on an Apple Silicon Mac**, Fargate runs `linux/amd64`, so build with the platform
   flag or your tasks will crash on start with an `exec format error`:
   ```bash
   docker buildx build --platform linux/amd64 -t matrix/auth-service:latest . --load
   ```
4. **Milestone Check:** Both repositories show an image tagged `latest` in the console.

### Step 2: Create the ECS Cluster and Networking

1. In the **ECS console**, click **Create cluster**. Name it `matrix-cluster`, choose
   **AWS Fargate (serverless)** as the infrastructure, and leave everything else default.
2. Create a **Service Connect namespace** when prompted (or under the cluster's
   **Service Connect** settings). Name it `matrix.local`. This is what turns the name `kafka`
   into an address the other tasks can reach.
3. Create a security group for the load balancer you will build in Step 5, called
   `matrix-alb-sg`, allowing inbound **3000** and **8080** from **Anywhere (0.0.0.0/0)**.
4. Create a second security group for the tasks, called `matrix-ecs-tasks-sg`. Inbound rules:
   * **Port 3000** and **port 8080**: source = `matrix-alb-sg`. Only the load balancer may talk
     to your services.
   * **Port 9092**: source = `matrix-ecs-tasks-sg` itself. Tasks talk to Kafka, nobody else does.
5. **Unlock the database for Fargate:** Edit the **RDS security group** (Lock 2 in Appendix B)
   and add a second inbound rule for **port 5432** with source `matrix-ecs-tasks-sg`. Leave the
   EC2 rule in place for now; you remove it during decommissioning.

### Step 3: IAM Roles for the Tasks

ECS uses two different roles. Getting them the wrong way round is the most common Stage 3 error.

* **Task Execution Role** (`matrixTaskExecutionRole`): used by ECS *itself* to pull the image
  from ECR, write logs to CloudWatch, and inject secrets into the container at startup. Create it
  with the AWS-managed policy `AmazonECSTaskExecutionRolePolicy`, then attach an inline policy
  allowing `secretsmanager:GetSecretValue` on
  `arn:aws:secretsmanager:*:*:secret:matrix/production/*`.
* **Task Role** (`matrixTaskRole`): used by *your code* at runtime for any AWS API calls. Give it
  the same `secretsmanager:GetSecretValue` inline policy. (You can reuse the
  `MatrixInstanceSecretsReaderRole` policy from Monday, but the trust relationship must be
  `ecs-tasks.amazonaws.com`, not `ec2.amazonaws.com`, so create a new role.)

### Step 4: Write the Task Definitions

Create three task definitions in the ECS console (**Task definitions -> Create new task
definition**). For each one choose **Fargate**, operating system **Linux/X86_64**, and the two
roles from Step 3. Enable **CloudWatch logging** (the `awslogs` driver) on every container; this
is your only window into a container that will not start.

#### 4a. `kafka` task definition
* **Image:** `apache/kafka:latest` (single-node KRaft mode, no ZooKeeper).
* **CPU / Memory:** 1 vCPU / 2 GB.
* **Port mapping:** container port `9092`, **port name** `kafka` (the port name is what Service
  Connect publishes).
* **Environment variables** (minimum set for a single broker):
  ```text
  KAFKA_NODE_ID=1
  KAFKA_PROCESS_ROLES=broker,controller
  KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093
  KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
  KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092
  KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
  KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
  KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1
  KAFKA_AUTO_CREATE_TOPICS_ENABLE=true
  ```
  The important line is `KAFKA_ADVERTISED_LISTENERS`. Kafka tells clients where to reconnect, and
  that address *must* be the Service Connect name, not `localhost`.

> ℹ️ Kafka's data lives on the task's ephemeral disk, so topics are lost if the task restarts.
> That is acceptable for this project. If you want durability, mount an **Amazon EFS** volume at
> `/var/lib/kafka/data`; it adds about twenty minutes.

#### 4b. `auth-service` task definition
* **Image:** your ECR URI, e.g. `123456789012.dkr.ecr.us-east-1.amazonaws.com/matrix/auth-service:latest`.
* **CPU / Memory:** 0.5 vCPU / 1 GB.
* **Port mapping:** container port `3000`, port name `auth`.
* **Environment variables:** `DB_HOST` = your RDS endpoint, `DB_PORT` = `5432`,
  `KAFKA_BOOTSTRAP_SERVERS` = `kafka:9092`, plus whatever else your service reads. Note that the
  Kafka host is no longer `localhost`.
* **Secrets:** instead of calling Secrets Manager from code, let ECS inject the values. Under
  **Environment variables**, change the type from *Value* to **ValueFrom** and give the secret ARN
  with a JSON key suffix, one per variable:
  ```text
  DB_PASSWORD        arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:matrix/production/credentials-XXXXXX:DB_PASSWORD::
  DB_USERNAME        arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:matrix/production/credentials-XXXXXX:DB_USERNAME::
  DB_NAME            arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:matrix/production/credentials-XXXXXX:DB_NAME::
  JWT_SHARED_SECRET  arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:matrix/production/credentials-XXXXXX:JWT_SHARED_SECRET::
  ```
  Copy the full ARN (including the random six-character suffix) from the Secrets Manager console.
  Your code then just reads ordinary environment variables, and your Tuesday SDK call can stay as
  a fallback or be removed.

#### 4c. `orders-service` task definition
Identical to 4b with the orders image, container port `8080`, port name `orders`, and
1 vCPU / 2 GB (the JVM wants the headroom).

### Step 5: Create the Application Load Balancer

1. In the **EC2 console -> Load Balancers**, create an **Application Load Balancer** named
   `matrix-alb`. Scheme **Internet-facing**, your default VPC, at least two public subnets, and
   the `matrix-alb-sg` security group.
2. Create two **target groups**, both with target type **IP addresses** (not Instances; Fargate
   tasks are not instances):
   * `matrix-auth-tg`: protocol HTTP, port `3000`, health check path `/api/auth/health` (or
     whatever health endpoint your service exposes).
   * `matrix-orders-tg`: protocol HTTP, port `8080`, health check path `/api/orders/health`.
   Do not register any targets; ECS does that for you.
3. Add two **listeners** on the ALB: port `3000` forwarding to `matrix-auth-tg`, and port `8080`
   forwarding to `matrix-orders-tg`. Keeping the same port numbers means your Angular code only
   needs a hostname change.
4. Copy the ALB's **DNS name** (e.g. `matrix-alb-1234567890.us-east-1.elb.amazonaws.com`).

### Step 6: Create the ECS Services

Create the services in this order, waiting for each to show **Running** before starting the next.
In each case: cluster `matrix-cluster`, launch type **Fargate**, desired tasks **1**, your default
VPC and public subnets, security group `matrix-ecs-tasks-sg`, and **Public IP: Turned on** (your
tasks sit in public subnets with no NAT gateway, so they need a public IP to pull images and reach
Secrets Manager).

1. **`kafka` service:** task definition `kafka`. Under **Service Connect**, choose
   **Client and server**, namespace `matrix.local`, and publish port `kafka` with the DNS name
   `kafka` on port `9092`. No load balancer.
2. **`auth-service` service:** task definition `auth-service`. Service Connect: **Client side
   only** (it needs to find Kafka but nothing needs to find it by name). Under **Load balancing**,
   choose the existing `matrix-alb` and target group `matrix-auth-tg`.
3. **`orders-service` service:** as above with `matrix-orders-tg`.

**Milestone Check:** In the ECS console each service shows **1/1 tasks running**, and in the EC2
console each target group shows its one target as **healthy**. Then from your laptop:
```bash
curl http://matrix-alb-1234567890.us-east-1.elb.amazonaws.com:3000/api/auth/health
curl http://matrix-alb-1234567890.us-east-1.elb.amazonaws.com:8080/api/orders/health
```

If a task cycles between *Pending* and *Stopped*, open the stopped task and read its
**Stopped reason** and **Logs** tab. The usual suspects, in order: the image platform (Step 1),
the execution role cannot read the secret (Step 3), the task security group cannot reach RDS
(Step 2), or the ALB health check path returns something other than 200.

### Step 7: Repoint the Frontends

1. In both Angular environment files, replace the EC2 IP with the ALB DNS name, keeping the ports:
   * `AUTH_API_URL` -> `http://matrix-alb-1234567890.us-east-1.elb.amazonaws.com:3000`
   * `ORDERS_API_URL` -> `http://matrix-alb-1234567890.us-east-1.elb.amazonaws.com:8080`
2. Rebuild both UIs (remember the Admin build flags from Appendix A), upload to their S3 buckets,
   and create a CloudFront invalidation for `/*`.
3. Your backend CORS configuration already allows your CloudFront origin, so nothing changes
   there; the browser's origin is still the CloudFront domain.
4. **Milestone Check:** Repeat Thursday's end-to-end test through CloudFront. Open the browser
   developer tools **Network** tab and confirm API calls are going to the ALB hostname, not the
   old EC2 IP. Watch the CloudWatch log group for `orders-service` and confirm your actions are
   producing log lines there.

At this point your application is fully running on Fargate and your EC2 instance is receiving no
traffic. The decommission below is safe.

---

### Step 8: Decommission the EC2 Instance

Do this in the order given. Everything up to and including step 3 is reversible; from step 4
onwards it is not, which is why those steps wait until after Friday's demo.

1. **Prove it is idle:** SSH into the instance and run `sudo docker compose logs --tail=50`. You
   should see no new requests since Step 7. If you do, something is still pointing at the old IP;
   fix that first.
2. **Stop the containers:**
   ```bash
   sudo docker compose down
   ```
   Re-run your end-to-end test through CloudFront. It should still pass, because nothing depends
   on this box any more.
3. **Stop (don't terminate) the instance:** In the EC2 console, **Instance state -> Stop
   instance**. A stopped instance costs only its disk. Leave it stopped until after Friday's demo
   so you have a one-click rollback: start it, run `docker compose up -d`, and repoint the
   frontends back to its IP.
4. **After the demo, terminate:** **Instance state -> Terminate instance**. Confirm the root
   volume is set to delete on termination (it is by default), otherwise delete the orphaned EBS
   volume under **Elastic Block Store -> Volumes**.
5. **Tidy the RDS firewall:** Edit the RDS security group and **remove** the inbound 5432 rule
   whose source is the EC2 security group. Only the `matrix-ecs-tasks-sg` rule should remain. This
   matters: an unused but still-trusted path into the database is exactly the kind of thing a
   security review flags. (It is done after termination so the rollback in step 3 still worked
   right up to the demo.)
6. **Remove the leftovers:**
   * Delete the EC2 security group (it will refuse while anything still references it, which is a
     useful check that step 5 was done).
   * Release any **Elastic IP** you allocated, or AWS will charge you for an unattached address.
   * Delete the IAM role `MatrixInstanceSecretsReaderRole` and its instance profile; the Fargate
     tasks use the roles from Step 3 instead.

**Final Check:** Your account should now contain CloudFront, two S3 buckets, one ALB, one ECS
cluster with three services, one RDS instance, one secret, and **no EC2 instances**. Run
`aws ec2 describe-instances --query 'Reservations[].Instances[].State.Name'` and confirm it returns
nothing but `terminated` (or an empty list).

### What You Have Achieved
Compare this with Monday's diagram. Every component you started with in a single `docker compose`
file is now running on a managed AWS service: the UI on S3 and CloudFront, the data on RDS, the
secrets in Secrets Manager, and the containers on Fargate behind a load balancer. The lab-shortcut
warning from Wednesday is resolved too: your services no longer expose a raw IP, and the next step
in production would be moving the tasks into private subnets behind the same ALB, exactly as
Appendix C describes.

---

# 🛠️ APPENDIX A: Wednesday Routing Configurations & Policies

Use these on Wednesday to stop CloudFront from breaking your Angular routing.

### 1. The CloudFront S3 Bucket Policy (Fixes 403 Forbidden UI Errors)
Your S3 buckets are private by default. To let CloudFront read the Angular files, apply this
**bucket policy** to *both* the Client and Admin buckets.

In the **S3 console**, select the bucket, open the **Permissions** tab, scroll to
**Bucket policy**, click **Edit**, and paste this JSON (replace the uppercase placeholders with
your own values):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCloudFrontProxyRead",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudfront.amazonaws.com"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::YOUR-S3-BUCKET-NAME/*",
            "Condition": {
                "StringEquals": {
                    "AWS:SourceArn": "arn:aws:cloudfront::YOUR-AWS-ACCOUNT-ID:distribution/YOUR-CLOUDFRONT-DISTRIBUTION-ID"
                }
            }
        }
    ]
}
```

### 2. The Angular Subdirectory Build Command (Fixes Blank Admin Screens)
The Client UI lives at the root (`/`) and the Admin UI lives at `/admin`. Unless you tell Angular
otherwise, the browser will look in the wrong folder for the Admin JavaScript chunks and you will
get a blank page.

When you build the Admin UI on Wednesday, use exactly this command:

```bash
ng build --configuration production --base-href=/admin/ --deploy-url=/admin/
```

---

# 🧱 APPENDIX B: Networking & Troubleshooting Guide (Security Groups, IAM & CORS)

Network connectivity blocks and CORS mismatches are the most common problems teams hit during the
week. Most of them come down to one of the three "locks" below. When something stops working,
check these first.

### What is an AWS Security Group?
Think of a security group as a **host-level virtual firewall** wrapped around a single resource
(an EC2 instance, an RDS database, and so on).

By default, AWS locks these firewalls down completely. Unless you add an explicit **inbound rule**
allowing traffic on a specific port, all incoming traffic is silently dropped. "Silently" is the
important word: you will see a timeout, not an error message telling you the port is blocked.

---

### The 3 Network Locks

#### 🟢 Lock 1: The EC2 Instance Security Group (Monday)
On Monday the EC2 instance hosts everything: Angular frontends, Node and Spring Boot APIs, and
Kafka.
*   **Where to find it:** **EC2 Dashboard -> Instances**, click your instance, select the
    **Security** tab, and click the security group link.
*   **Inbound rules you need:**
    1.  **Port 22 (SSH):** Source **My IP**, so only your team can SSH in.
    2.  **Port 80 (HTTP):** Source **Anywhere (0.0.0.0/0)**.
    3.  **Port 3000 (Node Auth):** Source **Anywhere (0.0.0.0/0)**.
    4.  **Port 8080 (Spring Boot Orders):** Source **Anywhere (0.0.0.0/0)**.
    5.  **Port 443 (HTTPS):** Source **Anywhere (0.0.0.0/0)**. Nothing uses it this week, but it
        saves a trip back here if you add TLS later.

*Symptom if this is wrong:* browser requests to your public IP time out, or SSH hangs.

#### 🟡 Lock 2: The RDS Security Group (Tuesday)
On Tuesday your data moves into RDS. By default the database blocks all incoming connections.
*   **Where to find it:** **RDS Dashboard -> Databases**, click your database, open the
    **Connectivity & security** tab, and click the security group link.
*   **The one inbound rule you need:**
    *   **Port 5432 (PostgreSQL):** Instead of opening this to the internet, copy the
        **security group ID of your EC2 instance** (e.g. `sg-01234abcd...`) and paste it into
        the **Source** field.
    *   *This tells AWS: "Block the whole world from this database, but allow anything running
        on our EC2 instance straight through."*

*Symptom if this is wrong:* your backend logs show database connection timeouts.

#### 🟣 Lock 3: The IAM Instance Role (Secrets Manager access)
If your backend containers crash on startup with an AWS **Access Denied** or permissions error,
your code cannot reach Secrets Manager.
*   **Where to find it:** **EC2 Dashboard -> Instances**, click your instance, select the
    **Details** tab, and check that the **IAM role** field has a value.
*   **Things to check, in order:**
    1. The role has a policy attached.
    2. The `Resource` in that policy matches the ARN of your secret (the wildcard from Monday
       should cover `matrix/production/credentials`).
    3. Your backend code uses the official AWS SDK to fetch `matrix/production/credentials`
       during startup, before the application routes are registered.

---

### Troubleshooting Checkpoints

1.  **CORS failures:** If the browser console shows `Access-Control-Allow-Origin missing`, check
    whether your backend is actually returning CORS headers. Run this from your laptop,
    substituting your own CloudFront domain and EC2 IP:
    ```bash
    curl -H "Origin: http://d12345xyz.cloudfront.net" --verbose http://[YOUR-EC2-PUBLIC-IP]:3000/api/auth/health
    ```
    Look for `Access-Control-Allow-Origin` in the response headers. If it is missing, the fix is
    in your backend CORS configuration, not in AWS.
2.  **Stale frontend after an upload:** A CloudFront invalidation for `/*` is your universal
    "refresh" button. If an Angular fix is in S3 but not in the browser, the edge is serving a
    cached copy. Create the invalidation and try again.
3.  **Tracing a failure:** When a layer stops responding or times out, trace the request from the
    edge downward and find the first hop that fails:

    `Browser ➔ CloudFront CDN ➔ Public Internet ➔ EC2 Instance Port ➔ RDS Firewall`

    After Stage 3 the middle of that chain becomes `ALB ➔ Target Group ➔ Fargate Task`.

---

# 🏢 APPENDIX C: What Production Looks Like (The Application Load Balancer)

In commercial environments, pointing a frontend directly at a single server's raw IP address is
strongly discouraged. For high availability and security compliance, cloud architects put an
**AWS Application Load Balancer (ALB)** in front of the compute layer.

### Why the Four-Day Plan Leaves Out the ALB
An ALB is billed by the hour whether or not it receives traffic, and it adds setup time for target
groups and listeners. Because your local Docker services already have **CORS (Cross-Origin
Resource Sharing)** configured, you can skip the ALB for the core week and still get a working,
demonstrable system. You should, however, understand the architecture below and be able to
explain in your presentation what you would change for production. If you complete Stage 3 you
will have built the ALB anyway, because Fargate tasks have no fixed IP address to point at.

### Production Target Architecture
A production deployment reintroduces the ALB and fully insulates the compute layer from direct
public exposure. The diagram shows the EC2 version; after Stage 3 the EC2 box becomes your
Fargate tasks and everything else is the same:

```text
                           [ User Browser ]
                                  │
                                  ▼
                      ┌───────────────────────┐
                      │    AWS CLOUDFRONT     │  <-- Top-Level Gateway
                      │ (d12345xyz.cloudfront.net)
                      └───────────┬───────────┘
                                  │
         ┌────────────────────────┼────────────────────────┐
         │ Path is /              │ Path is /admin*        │ Path is /api/*
         ▼                        ▼                        ▼
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│  AWS S3 BUCKET  │      │  AWS S3 BUCKET  │      │     AWS ALB     │ <-- Inner Path Router
│    (Client)     │      │     (Admin)     │      └────────┬────────┘
└─────────────────┘      └─────────────────┘               │
 (Static Angular)         (Static Angular)                 ├────────────────────────┐
                                                           │ Path is /api/auth/*    │ Path is /api/orders/*
                                                           ▼                        ▼
                                                   ┌────────────────────────────────────────┐
                                                   │             AWS EC2 INSTANCE           │
                                                   │                                        │
                                                   │  ┌──────────────────┐  ┌────────────┐  │
                                                   │  │   Node.js Auth   │  │Spring Boot │  │
                                                   │  │     Service      │  │Orders Serv.│  │
                                                   │  └────────┬─────────┘  └──────┬─────┘  │
                                                   │           │                   │        │
                                                   │           ▼                   ▼        │
                                                   │  ┌──────────────────────────────────┐  │
                                                   │  │     Apache Kafka (Local Pod)     │  │
                                                   │  └──────────────────────────────────┘  │
                                                   └─────────────────────┬──────────────────┘
                                                                         │
                                                                         ▼
                                                   ┌────────────────────────────────────────┐
                                                   │      AMAZON AURORA / RDS POSTGRES      │
                                                   └────────────────────────────────────────┘
```

### What the ALB Buys You

1. **Unified Path Routing (No CORS):** CloudFront forwards `/api/*` traffic to the ALB, so the
   browser only ever talks to a single hostname. Client-side CORS is no longer needed.
2. **Private Network Insulation:** With the ALB in a public subnet, your EC2 instances can move
   into **private subnets** with no public IP at all. Brute-force SSH attempts and port scanners
   never reach them.
3. **Horizontal Scaling:** Instead of one large server, target groups let you run the same
   containers across several smaller EC2 instances behind a single entry point, scaling out
   automatically on CPU or memory pressure.
