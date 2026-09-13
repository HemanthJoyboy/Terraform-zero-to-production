# MERN Todo — Dockerized (Node + Express + React + Postgres, all in containers)

This is the Dockerized version of the `mern-todo-monorepo` project. The
manual/PM2 approach (`ecosystem.config.js`, installing Node directly on an
EC2 box) still works and is untouched — this repo adds a **second,
container-based way** to run and deploy the exact same app, now including
its own database:

```
mern-todo-docker/
├── client/                  # React (Vite) → built, then served by Nginx    → container port 80  (host 3000)
├── services/
│   ├── api-gateway/         # proxies requests                              → container port 4000 (host 4000)
│   ├── auth-service/        # register/login, issues JWTs                   → container port 4001 (internal only)
│   └── todo-service/        # CRUD todos, verifies JWTs                     → container port 4002 (internal only)
├── docker-compose.yml               # defines & wires up all 5 containers, including postgres
├── docker-compose.override.yml      # auto-loaded dev overrides (hot reload via bind mounts)
├── k8s/                      # Kubernetes manifests - see README-k8s.md
├── README-k8s.md             # Kubernetes / AWS EKS version of this whole guide
└── ecosystem.config.js      # kept from the manual setup, for reference
```

**Running this on Kubernetes instead?** See [`README-k8s.md`](./README-k8s.md)
— same app, same 5 pieces, deployed to a real multi-node cluster (AWS EKS)
instead of one Docker host. Covers why Kubernetes over Compose, the full
architecture, every concept mapped to this app, and a complete step-by-step
EKS deployment.

**Provisioning that EKS cluster with Terraform, the way a real MNC would?**
See [`README-terraform.md`](./README-terraform.md) — requirements-gathering,
the `infra/` module + environment folder structure, dev/test/prod as
separate clusters, the real change-review workflow, and why infra and app
get separate CI/CD pipelines (`.github/workflows/`).

**The database has changed:** this version no longer uses Neon (external,
managed Postgres). It runs **Postgres itself as a 5th container**, with a
Docker **volume** so the data survives restarts and redeploys. Everything —
app code and database — now lives entirely inside Docker on your own
server; there's no external service to sign up for or depend on.

---

## 1. What is Docker, and why use it over the manual approach?

**Docker packages an application together with everything it needs to run**
(Node runtime, exact npm dependency versions, OS libraries, config) into a
single unit called an **image**. A running instance of that image is a
**container** — an isolated process with its own filesystem, network
interface, and process tree, but sharing the host machine's kernel (which is
what makes it much lighter than a full virtual machine).

### Manual approach (what this project used before)

On the EC2 box, you had to, by hand:

1. Install Node.js 20 (and hope it matches what you developed with)
2. Install PM2, `serve`, git
3. `npm install` in the repo root (which installs for all 4 services)
4. Manually create 4 `.env` files
5. Build the client
6. Start 4 processes with `ecosystem.config.js`
7. Hope the server's OS libraries, Node version, and installed globals match
   your laptop closely enough that "it worked on my machine" holds

This works, but has real problems:

| Problem | Why it happens |
|---|---|
| "Works on my machine" bugs | Your laptop's Node/OS/library versions silently drift from the server's over time |
| Hard to run 2 apps with conflicting needs on one box | Both would fight over global Node version, global npm packages, ports |
| New team member setup takes hours | They must install Node, PM2, git, clone, npm install, create 4 env files, remember every step correctly |
| Scaling a single service (e.g. todo-service) is awkward | PM2 can fork the *same* process, but you're still tied to that one server's OS/CPU |
| Rebuilding a fresh server after a crash/migration | You must redo all of section 5.2–5.6 of the manual README from scratch |

### Docker approach

1. Write a `Dockerfile` **once** per service describing exactly how to build
   it (base image, dependencies, source, start command)
2. `docker build` turns that into an image — a self-contained, versioned
   artifact that includes the exact Node version and exact `npm install`
   result baked in
3. `docker run` (or `docker compose up`) starts it as a container — same
   behavior every time, on your laptop, a teammate's laptop, or the server,
   because it's the *same image*
4. New server setup = install Docker + `docker compose up -d`. That's it —
   no Node version to match, no PM2 config to remember, no manual `.env`
   copy-paste sequence beyond the env files themselves

**In short:** the manual approach configures a *server*; Docker packages an
*application*. You stop asking "is this server set up correctly?" and start
asking "does this image run?" — which you can test locally before it ever
touches production.

This isn't "Docker replaces PM2" in spirit — it replaces the whole idea of
manually preparing a machine. You could even run PM2 *inside* a container,
but the point of Docker here is that each service already ships with its
correct runtime, so you don't need a process manager to babysit
version drift.

---

## 2. Docker architecture — how a request flows, and who handles it

Docker isn't just the `docker` command — it's a client/server system:

```
┌──────────────────────────────── Host machine (your laptop or EC2) ────────────────────────────────┐
│                                                                                                     │
│   docker CLI  ──REST API (over a Unix socket)──▶  dockerd (Docker daemon)                          │
│  (docker run,                                       - builds images (reads your Dockerfile)        │
│   docker compose,                                   - manages containers (start/stop/restart)       │
│   docker ps, ...)                                   - manages networks & volumes                    │
│                                                       - talks to containerd + runc underneath        │
│                                                              │                                       │
│                                                              ▼                                       │
│                                          containerd  (manages container lifecycle)                   │
│                                                              │                                       │
│                                                              ▼                                       │
│                                          runc  (actually creates the isolated process:                │
│                                                 Linux namespaces + cgroups)                            │
│                                                              │                                       │
│         ┌──────────────┬───────────────┬────────────────────┼──────────────┬─────────────┐          │
│         ▼              ▼               ▼                    ▼              ▼             │          │
│   [client         [api-gateway]   [auth-service]      [todo-service]   [postgres]         │          │
│    container]       :4000           :4001                 :4002          :5432            │          │
│    nginx :80                                                                                          │
│         │                │               │                    │              │                       │
│         └──── todo-net (Docker's internal virtual bridge network + built-in DNS) ────────────────────┘
│                                                                          │                             │
│                                                          pgdata (named volume, on the host's disk)     │
│                                                                                                        │
└──────────────── host ports published: 3000→client:80, 4000→api-gateway:4000 ─────────────────────────┘
```
`postgres` has **no** `-p`/`ports:` entry at all — same rule as
auth-service/todo-service. Nothing outside Docker can reach it directly;
only auth-service and todo-service, over `todo-net`, ever talk to it.

**Who handles what:**
- **Docker CLI** — the `docker` / `docker compose` commands you type. It's just a client; it doesn't run containers itself.
- **Docker daemon (`dockerd`)** — the long-running background service that actually does the work: builds images layer by layer, creates/starts/stops containers, creates networks and volumes.
- **containerd + runc** — lower-level components `dockerd` delegates to for actually creating the isolated Linux process (using kernel namespaces for isolation and cgroups for resource limits). You never call these directly.
- **Docker network (`todo-net`)** — a private virtual network Compose creates. Containers on it can resolve each other **by service name** (e.g. `api-gateway` can reach `http://auth-service:4001`) via Docker's built-in embedded DNS server.

### Request flow for "user clicks Login"

1. Browser (on your machine) sends `POST http://<server-ip>:3000` request → hits the **host's** network stack on port 3000
2. Docker's port-publishing rule (`3000:80` in compose) forwards that to the **client container's** nginx on port 80, which returns the already-built React app (nginx here is just a static file server — no proxying)
3. The React app's JS (running in the *browser*, not in any container) calls `fetch('http://<server-ip>:4000/api/auth/login')`
4. That hits the **host** on port 4000 → Docker's `4000:4000` mapping forwards it into the **api-gateway container**
5. Inside `api-gateway`, `http-proxy-middleware` forwards the request to `http://auth-service:4001/login` — this hop **never leaves the Docker network**; it's resolved by Docker's internal DNS to auth-service's container IP on `todo-net`
6. `auth-service` queries `http://postgres:5432` — same story, **another hop that never leaves `todo-net`**, resolved to the `postgres` container by name, verifies the password, signs a JWT
7. Response flows back: postgres → auth-service → api-gateway → host port 4000 → browser

The key architectural shift from the manual setup: `localhost:4001` (same
machine, same OS process space) becomes `auth-service:4001` (a different
container, reached by **service name** over the Docker network) — because
each service is now its own isolated container with its own `localhost`.

---

## 3. Steps to create a Dockerfile

Using `services/auth-service/Dockerfile` in this repo as the running example:

1. **Pick a base image** — start from an image that already has what you need. We use `node:20-alpine` (`alpine` = a minimal Linux distro, keeps the image small).
   ```dockerfile
   FROM node:20-alpine
   ```
2. **Set a working directory** — everywhere from this line down, `COPY`/`RUN` operate relative to this path inside the container.
   ```dockerfile
   WORKDIR /app
   ```
3. **Copy dependency manifests first, install, then copy source code** — this ordering is deliberate for **layer caching**: Docker caches each instruction. If `package.json` hasn't changed, Docker reuses the cached `npm install` layer instead of re-running it, so rebuilding after a small code change takes seconds, not minutes.
   ```dockerfile
   COPY package*.json ./
   RUN npm install --omit=dev
   COPY src ./src
   ```
4. **Drop root privileges** (security best practice — a container running as root has more power than it needs).
   ```dockerfile
   RUN addgroup -S appgroup && adduser -S appuser -G appgroup
   USER appuser
   ```
5. **Document the port** the app listens on (this is informational metadata only — it doesn't publish anything by itself; you still need `-p` or a compose `ports:` entry).
   ```dockerfile
   EXPOSE 4001
   ```
6. **Define the startup command** — what runs when a container starts from this image.
   ```dockerfile
   CMD ["node", "src/index.js"]
   ```

For the **client**, the Dockerfile is a **multi-stage build** because Vite
needs Node.js to *build* the app, but the *running* app is just static
HTML/JS/CSS that only needs a web server:

- **Stage 1 (`builder`)**: `node:20-alpine`, installs devDependencies, runs `npm run build`, produces `/app/dist`
- **Stage 2 (final image)**: fresh `nginx:1.27-alpine`, copies only `dist/` from Stage 1 via `COPY --from=builder`

Everything from Stage 1 (Node, node_modules, source files) is discarded —
only the compiled static files make it into the final image, which is why
multi-stage builds produce much smaller production images than "just
install everything in one stage" would.

### Also worth knowing: `.dockerignore`
Every service here has a `.dockerignore` (same idea as `.gitignore`) that
excludes `node_modules`, `.env`, and `.git` from what gets sent to the
Docker daemon during `docker build`. Without it, your **real secrets**
(`.env` with your Postgres password/JWT secret) could get baked into an
image layer.

---

## 4. Steps to run a Dockerfile

### Build the image
```bash
cd services/auth-service
docker build -t auth-service:1.0 .
```
- `-t auth-service:1.0` — tags (names) the image so you can refer to it later. Format is `name:tag`.
- `.` — the **build context**: the folder Docker sends to the daemon and where it looks for the Dockerfile.

### Run a container from it
```bash
docker run -d \
  --name auth-service \
  --env-file .env \
  -p 4001:4001 \
  auth-service:1.0
```
- `-d` — detached, runs in the background
- `--name` — a friendly name instead of a random one Docker would otherwise generate
- `--env-file .env` — injects your `DATABASE_URL` / `JWT_SECRET` as environment variables inside the container (this is how config gets in — nothing is hardcoded into the image)
- `-p 4001:4001` — publish container port 4001 to host port 4001 (`host:container`)

### Everyday commands
```bash
docker ps                     # list running containers
docker ps -a                  # include stopped ones
docker logs -f auth-service   # tail logs (equivalent of pm2 logs)
docker exec -it auth-service sh   # get a shell inside the running container
docker stop auth-service
docker rm auth-service        # remove a stopped container
docker rmi auth-service:1.0   # remove the image
```

Doing this one container at a time for all 4 app services (plus postgres) works, but you'd have
to manually create a network and pass `--network` to every command so they
can reach each other. **That's exactly what `docker compose` automates** —
see Section 6. Section 5 below walks through doing it by hand first, since
seeing the manual version is the fastest way to actually understand what
Compose is doing for you.

---

## 5. Running all 5 containers manually (no Compose yet)

This section skips `docker-compose.yml` entirely and wires everything up
with plain `docker run`, so the networking actually makes sense before a
tool starts doing it for you. There are 5 containers now, not 4 — Postgres
itself runs in a container too, instead of using an external Neon database.

### Two things that trip up almost everyone new to this

**1. `EXPOSE` in a Dockerfile does nothing by itself.** It's just
documentation — a note to anyone reading the Dockerfile saying "this app
listens on port 4000." It doesn't open any door. The thing that actually
connects a port to the outside world is the `-p` flag on `docker run` (or
`ports:` in Compose).

**2. Containers can't find each other by name unless you put them on the
same *custom* network.** If you just `docker run` with no `--network` flag,
Docker puts the container on a default network called `bridge`, and on that
default network, containers **cannot** resolve each other by name — there's
no built-in DNS there. You'd have to hardcode fragile container IP
addresses. The fix is to create your own network first — Docker gives
*that* one automatic DNS, where each container's `--name` becomes a working
hostname for the others on it.

### Step 1 — create a network first

```bash
docker network create todo-net
```
This creates a private virtual switch on your machine. Nothing is running
on it yet — you're just laying down the "table" that containers will sit at
together.

### Step 2 — start `postgres`, with a volume, on that network

```bash
docker volume create pgdata

docker run -d \
  --name postgres \
  --network todo-net \
  -e POSTGRES_USER=todo \
  -e POSTGRES_PASSWORD=todo \
  -e POSTGRES_DB=tododb \
  -v pgdata:/var/lib/postgresql/data \
  -v $(pwd)/services/auth-service/sql/schema.sql:/docker-entrypoint-initdb.d/01-auth.sql:ro \
  -v $(pwd)/services/todo-service/sql/schema.sql:/docker-entrypoint-initdb.d/02-todo.sql:ro \
  postgres:16-alpine
```
Also **no `-p` flag** — exactly like auth-service/todo-service, nothing
outside Docker needs to reach Postgres directly, only the other two
containers, over `todo-net`.

The `-v pgdata:/var/lib/postgresql/data` line is a **named volume** — it's
what makes your data survive a `docker rm postgres` later. The two
`schema.sql` mounts are a real, working example of the official Postgres
image's auto-init feature: any `.sql` file dropped into
`/docker-entrypoint-initdb.d` runs **automatically, exactly once**, the
first time the container starts against an empty volume.

Give it a moment to finish initializing before starting anything that
depends on it:
```bash
docker exec postgres pg_isready -U todo -d tododb
# repeat until it prints "accepting connections" instead of erroring
```

#### Postgres container authentication — who's the "root" user, and how does the password actually work?

This trips people up the first time, so worth spelling out precisely:

- **There's no separate "root" concept here** — whatever you set
  `POSTGRES_USER` to (here, `todo`) simply **becomes the Postgres
  superuser** for this entire instance, with full rights to create/drop
  databases, tables, and other users. It's the closest thing to "root," and
  it's also your everyday app user in this setup. (A real production setup
  would typically create a second, less-privileged role for the app to use
  day-to-day — not necessary for a learning project like this one.)
- **These env vars are read ONCE — only on a truly empty volume.** The
  first time `postgres:16-alpine` starts and finds nothing in
  `/var/lib/postgresql/data`, its entrypoint script runs an initialization
  routine: it creates the actual Postgres cluster on disk, creates the
  `POSTGRES_USER` role as superuser with `POSTGRES_PASSWORD` as its
  password, and creates `POSTGRES_DB` as a database owned by that role.
  After that, the role and its (hashed) password live **inside the data
  files on your `pgdata` volume** — inside Postgres's own internal catalog
  tables, not in any plaintext file. If you later change `POSTGRES_PASSWORD`
  and just restart the same container against the same volume, **nothing
  happens** — Postgres already exists, so it never re-reads that variable.
  To truly reset it you'd either run `ALTER USER todo WITH PASSWORD
  'newpass';` yourself, or wipe the volume and let it re-initialize from
  scratch (which deletes all your data — see the cleanup warning below).
- **Your app doesn't "know" the password automatically — you tell it
  twice, and it's on you to keep both copies in sync.** The `postgres`
  container gets its credentials from `POSTGRES_USER`/`POSTGRES_PASSWORD`
  above. `auth-service`/`todo-service` get told the *same* credentials
  separately, via `DATABASE_URL=postgres://todo:todo@postgres:5432/tododb`
  in their own `.env` files. There's no automatic link between the two —
  if they ever don't match (e.g. you change one but not the other), you'll
  get `password authentication failed for user "todo"` in the app's logs.
- **You can inspect this yourself:**
  ```bash
  docker exec -it postgres psql -U todo -d tododb
  ```
  Then, inside the `psql` prompt:
  ```sql
  \du     -- lists roles and their privileges - you'll see "todo" marked Superuser
  \l      -- lists databases - you'll see "tododb" owned by "todo"
  \dt     -- lists tables in the current database (users, or todos)
  \q      -- quit
  ```

### Step 3 — start `auth-service`, attached to that network

```bash
cd services/auth-service
docker build -t auth-service:1.0 .

docker run -d \
  --name auth-service \
  --network todo-net \
  --env-file .env \
  auth-service:1.0
```
Notice: **no `-p` flag here.** We deliberately don't publish this one to
the host — nothing outside Docker should ever reach `auth-service`
directly. It's still fully reachable, just only *from other containers on
`todo-net`*.

### Step 4 — start `todo-service`, same network

```bash
cd services/todo-service
docker build -t todo-service:1.0 .

docker run -d \
  --name todo-service \
  --network todo-net \
  --env-file .env \
  todo-service:1.0
```
Same deal — no `-p`, internal only.

### Step 5 — start `api-gateway`, published to the host, pointed at the other two by name

```bash
cd services/api-gateway
docker build -t api-gateway:1.0 .

docker run -d \
  --name api-gateway \
  --network todo-net \
  -p 4000:4000 \
  -e AUTH_SERVICE_URL=http://auth-service:4001 \
  -e TODO_SERVICE_URL=http://todo-service:4002 \
  --env-file .env \
  api-gateway:1.0
```
This is the key moment: `http://auth-service:4001` — that hostname
`auth-service` is *literally the `--name` you gave the other container*.
Because all three are on `todo-net`, Docker's internal DNS resolves
`auth-service` to whatever internal IP that container happens to have right
now. You never need to know or hardcode that IP.

`-p 4000:4000` means "take port 4000 on my actual machine, and forward it
into this container's port 4000." That's the only one of these three
getting a hole punched through to the outside world.

### Step 6 — start `client`, published to the host too

```bash
cd client
docker build -t client:1.0 --build-arg VITE_API_BASE_URL=http://<server-ip>:4000 .

docker run -d \
  --name client \
  --network todo-net \
  -p 3000:80 \
  client:1.0
```
The client doesn't actually *need* to be on `todo-net` for anything to
work — it doesn't talk to the other containers directly. The browser does,
over the internet/host network, using the URL baked into the JS at build
time. Being on `todo-net` here is harmless but not load-bearing.

### The rules this whole exercise is teaching you

**Reaching a container from your laptop/browser:** you must go through a
`-p host:container` mapping. Only `client` (3000→80) and `api-gateway`
(4000→4000) have one, so only those two are reachable from outside.
`auth-service` and `todo-service` have no `-p` at all — there is no path in
from outside, period, not even from `localhost` on the host machine.

**One container reaching another:** the `-p` mappings are irrelevant here —
that's a host-facing concept. What matters is `--network todo-net` and
using the target's **container name** as the hostname, on its **container
port** (not any host port). That's why `api-gateway` calls
`http://auth-service:4001`, never `http://localhost:4001` — `localhost`
inside `api-gateway`'s container means *itself*, not the auth-service
container.

### Try this once it's running, to make it click

```bash
docker network inspect todo-net          # see all 5 containers listed with their internal IPs

docker exec -it api-gateway sh
# then, inside that shell:
ping auth-service                        # resolves via Docker's DNS
curl http://auth-service:4001/health     # reaches it, over todo-net
curl http://localhost:4001/health        # fails - nothing listens on api-gateway's OWN port 4001
```

**Prove the volume is actually doing something:** register a user through
the app, then:
```bash
docker rm -f postgres                    # delete the CONTAINER (not the volume)

docker run -d \
  --name postgres \
  --network todo-net \
  -e POSTGRES_USER=todo \
  -e POSTGRES_PASSWORD=todo \
  -e POSTGRES_DB=tododb \
  -v pgdata:/var/lib/postgresql/data \
  postgres:16-alpine
# no schema.sql mounts needed this time - the volume already has the tables
```
Log in again with the same user — it still works, because the volume
(`pgdata`) was never touched, only the container was. Compare that with
running `docker volume rm pgdata` afterward, which *does* delete the user
permanently (this is exactly what Section 8 explains in more depth).

### Cleaning up the manual setup

```bash
docker stop client api-gateway todo-service auth-service postgres
docker rm client api-gateway todo-service auth-service postgres
docker network rm todo-net

# This does NOT delete your data - the volume survives both of the above.
# Only do this if you actually want to wipe the database permanently:
# docker volume rm pgdata
```

Once this clicks, `docker-compose.yml` will make a lot more sense — it's
really just automating exactly these `docker network create` +
`docker run --network ... --name ...` steps for you, one block per service,
which is what the rest of this README uses from here on.

---

## 6. Deploying the application using Docker containers

### 6.1 One-time server setup
On a fresh Ubuntu server (EC2 or otherwise) — this replaces *all* of the old
"install Node, PM2, git, npm install" steps:
```bash
# Install Docker Engine + Compose plugin
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # avoid needing sudo for every docker command
newgrp docker                   # re-evaluate group membership in this shell
docker --version
docker compose version
```

Security group / firewall — same rule as the manual setup, Docker doesn't
change the networking story at the host level. **If you're fronting the
frontend with your own host-level Nginx + a domain** (see 6.8 below — this
is the current setup for `todo.crashloop.in`), the rule changes slightly:
- Open **22** (SSH) — your IP only
- Open **80** (and later 443, once you add TLS) — public. This is your
  host Nginx, which reverse-proxies to the `client` container on `3000`.
- Open **4000** (api-gateway) — still public, still exposed **directly**
  (not through Nginx or the domain) — the client's JS calls it straight on
  its own port
- **Close 3000 to the outside world** — since Nginx now sits in front of
  it, the only thing that needs to reach port 3000 is Nginx itself, running
  on `localhost` on the same machine. See the Docker Compose change in 6.8.
- **Do NOT open 4001/4002** — they're not even published to the host in `docker-compose.yml`, so this is enforced by the compose file itself, not just the firewall

*(If you're not using a domain/reverse proxy at all, the original rule
still applies: open 3000 and 4000 directly, skip 80/443.)*

### 6.2 Get the code onto the server
```bash
git clone <your-repo-url> mern-todo-docker
cd mern-todo-docker
```

### 6.3 Configure environment files
Same `.env` files as the manual setup, one per service — Docker doesn't
change what goes in them, only that they're passed via `env_file:` in
compose instead of being read directly off disk by a PM2 process.
```bash
cp services/auth-service/.env.example services/auth-service/.env
cp services/todo-service/.env.example services/todo-service/.env
cp services/api-gateway/.env.example services/api-gateway/.env
cp .env.example .env   # sets VITE_API_BASE_URL AND the postgres bootstrap creds

nano services/auth-service/.env   # set a strong JWT_SECRET (DATABASE_URL default is already correct)
nano services/todo-service/.env   # SAME JWT_SECRET as auth-service
nano .env                         # VITE_API_BASE_URL=http://todo.crashloop.in:4000
                                   # POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB - change the
                                   # password from the "todo" default before any real deployment
```
Note it's `todo.crashloop.in:4000`, not just `todo.crashloop.in` — the
gateway is being kept on its own port rather than proxied through the
domain (see 6.8), so the client's compiled JS needs the `:4000` to reach
it. DNS already resolves `todo.crashloop.in` to your server, so this works
identically to using the raw IP, just with a stable hostname instead.

**If you change `POSTGRES_PASSWORD` in the root `.env`, also update
`DATABASE_URL` in both `services/auth-service/.env` and
`services/todo-service/.env` to match** — see Section 5's "Postgres
container authentication" writeup for why these two are separate values
that don't sync automatically, and only for a brand-new (empty) `pgdata`
volume anyway, since existing volumes keep whatever password they were
first created with.

### 6.4 Build and start everything
```bash
docker compose -f docker-compose.yml up -d --build
```
- `-f docker-compose.yml` — explicitly use only the production file (skip the dev-only `docker-compose.override.yml`, which Compose would otherwise auto-load)
- `--build` — build fresh images from the Dockerfiles instead of using anything cached from before
- `-d` — detached, keeps running after you disconnect

Compose reads `docker-compose.yml`, and for each service: builds its image
(if not already built), creates `todo-net` if it doesn't exist, starts each
container attached to that network, and applies the `ports:` mappings.

### 6.5 Verify
```bash
docker compose ps                       # see all 5 containers and their status/health
                                         # postgres should show "healthy", not just "running"
docker compose logs -f                  # tail logs from all services
docker compose logs -f auth-service     # logs from just one

curl http://localhost:4000/health       # api-gateway, from the host
docker compose exec api-gateway wget -qO- http://auth-service:4001/health   # prove internal DNS works
docker compose exec postgres psql -U todo -d tododb -c '\dt'                # confirm the tables exist
```
Then visit `http://todo.crashloop.in` in a browser (port 80, via your host
Nginx — see 6.8 below for what that config does and one thing to check).

### 6.6 Redeploying after a code change
```bash
git pull
docker compose up -d --build   # only rebuilds images whose Dockerfile/context actually changed
```
This is the single biggest operational win over the manual approach — one
command instead of re-running `npm install`, rebuilding the client, and
`pm2 restart`ing the right processes in the right order.

### 6.7 Common lifecycle commands
```bash
docker compose stop                 # stop containers, keep them (and the network) around
docker compose start                # start them again
docker compose restart auth-service # restart just one
docker compose down                 # stop AND remove containers + the network (images/volumes untouched)
docker compose down -v              # ALSO deletes the pgdata volume - i.e. every user and todo, permanently (see Section 8)
```

### 6.8 Domain + host-level Nginx in front of the client (your current setup)

If you already have Nginx installed **directly on the server** (not in a
container) configured to route `todo.crashloop.in` on port 80 to `3000`,
here's exactly how that fits with everything above:

```
Browser → todo.crashloop.in:80 → host Nginx → localhost:3000 → [client container] nginx:80
Browser → todo.crashloop.in:4000 (or the raw server IP:4000) → [api-gateway container] :4000  (unchanged, not touched by host Nginx)
```

A config like yours typically looks like this:
```nginx
server {
    listen 80;
    server_name todo.crashloop.in;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```
That's fine as-is and needs **no changes on the Nginx side** since you're
keeping the gateway on its own port rather than proxying `/api` through the
domain. Two things worth doing on the **Docker side** to match it, though:

1. **Stop publishing port 3000 to the whole internet.** Right now
   `docker-compose.yml` has `"3000:80"`, which binds to `0.0.0.0` — meaning
   anyone could still hit `http://<server-ip>:3000` directly, bypassing
   Nginx and your domain entirely. Since only your host Nginx needs to
   reach that port now, bind it to localhost only:
   ```yaml
   client:
     ports:
       - "127.0.0.1:3000:80"   # was: "3000:80"
   ```
   Nginx running on the same host can still reach `127.0.0.1:3000` just
   fine; nothing external can anymore. This repo's `docker-compose.yml`
   already has this applied.

2. **Watch for mixed-content issues once you add HTTPS.** The moment you
   put a TLS certificate on `todo.crashloop.in` (e.g. via Certbot) so the
   site loads over `https://`, the browser will refuse to let that HTTPS
   page call the gateway over plain `http://todo.crashloop.in:4000` — this
   is what browsers call "mixed content" and they block it silently. At
   that point you have two options:
   - Also proxy `/api` through the same Nginx + domain (so the client
     calls `https://todo.crashloop.in/api/...` and Nginx forwards to
     `localhost:4000` internally) and rebuild the client with
     `VITE_API_BASE_URL=https://todo.crashloop.in`, or
   - Put a **separate** cert on the gateway port (a second `server { listen
     4000 ssl; ... }` Nginx block, or a small reverse-proxy container
     dedicated to the gateway).

   Either is a small follow-up, not something you need to solve before
   your first deploy over plain HTTP.

### 6.9 (Optional, recommended) Docker also survives reboots
```bash
# Compose already sets restart: unless-stopped on every service, so as long
# as the Docker daemon itself starts on boot (it does, by default, once
# installed via get.docker.com/apt), all 5 containers come back up
# automatically after a server reboot - no pm2 save / pm2 startup needed.
sudo systemctl enable docker
```

---

## 7. How a request flows *inside* the containers

Zooming into just the container layer (compare with the full diagram in
Section 2, and the manual step-by-step version in Section 5):

```
Browser
  │  GET http://<server-ip>:3000/
  ▼
[client container]  nginx:80 → returns index.html + JS bundle (static files only, no backend logic here)
  │
  │  (from here on, calls are made by JS running in the BROWSER, not the client container)
  │  fetch('http://<server-ip>:4000/api/todos', { headers: { Authorization: 'Bearer <jwt>' } })
  ▼
Host port 4000  ──Docker port mapping──▶  [api-gateway container] :4000
  │
  │  http-proxy-middleware rewrites path, forwards over todo-net using the
  │  service name as hostname (Docker's embedded DNS resolves it to the
  │  todo-service container's internal IP, e.g. 172.19.0.4)
  ▼
[todo-service container] :4002
  │  requireAuth middleware verifies the JWT using JWT_SECRET (an env var
  │  injected via env_file - identical value in both auth-service and
  │  todo-service containers, exactly like the manual setup required)
  │  queries DATABASE_URL=postgres://todo:todo@postgres:5432/tododb - this
  │  hop ALSO never leaves todo-net; "postgres" resolves via Docker's DNS
  │  to the postgres container's internal IP, same mechanism as
  │  "auth-service" and "todo-service" did above
  ▼
[postgres container] :5432 → reads/writes pgdata (the named volume, actually on the host's disk)
  │
  ▼ rows flow back: postgres → todo-service → api-gateway → host:4000 → browser
```

Two things that are *different* from running the same code with PM2 on one
server, but *identical in effect*:
- **`localhost` no longer works between services** — each container has its
  own network namespace with its own `localhost`. `auth-service` calling
  `localhost:4002` would hit *itself*, not todo-service. That's why
  `docker-compose.yml` sets `AUTH_SERVICE_URL=http://auth-service:4001` —
  container **names/service names act as hostnames** on the shared network.
- **Only published ports are reachable from outside** — 4001, 4002, and
  now 5432 (postgres) have no `ports:` entry at all, so there is no route
  from the host (or the internet) into those containers, full stop. It's
  not just a firewall rule you could forget — the mapping simply doesn't
  exist.

---

## 8. Docker volumes and networks

### Networks
A Docker network is a private virtual network that containers attach to.
This repo defines one:
```yaml
networks:
  todo-net:
    driver: bridge
```
- **`bridge`** is the default driver for a single-host setup like this one — it creates an isolated virtual switch that containers plug into.
- Containers on the same network reach each other **by service name** via Docker's built-in DNS (see Sections 2, 5, and 7) — no hardcoded IPs, and the IPs can change across restarts without breaking anything.
- Containers **not** on the same network can't reach each other at all by default — this is what makes "don't expose 4001/4002 publicly" enforceable at the Docker level, not just a firewall convention.
- You can inspect it: `docker network inspect mern-todo_todo-net`

### Volumes
A volume is how a container persists or shares data **beyond its own
lifecycle** — a container's own filesystem is deleted the moment the
container is removed, so anything the app writes that needs to survive
`docker compose down` or a redeploy must live in a volume instead.

This app's actual data (`users`, `todos`) now lives **inside the `postgres`
container**, so this matters for real: without a volume, deleting or
recreating that one container — which happens routinely, e.g. every time
you `docker compose down` or bump the Postgres image version — would wipe
every user and every todo. Two volume patterns show up in this repo, for
two different reasons:

**1. Named volume, for real persistent data** (`docker-compose.yml`, always on):
```yaml
services:
  postgres:
    volumes:
      - pgdata:/var/lib/postgresql/data
volumes:
  pgdata:
```
A named volume is storage **managed by Docker itself** (you don't choose
the host path — Docker does, typically somewhere under
`/var/lib/docker/volumes/`). It survives `docker compose down`, container
removal, and image rebuilds — the container can be deleted and recreated
as many times as you like, and the moment the new one mounts `pgdata`
again, all the old data is right there. Only `docker compose down -v` or
`docker volume rm pgdata` deletes it — and Section 5 has a step you can run
yourself to actually watch this happen (delete the postgres container,
recreate it, log in with the same user — it still works).

```bash
docker volume ls                 # list all volumes on this machine
docker volume inspect pgdata     # see where Docker actually stores it on disk, plus which container uses it
```

**2. Bind mount, for local development** (`docker-compose.override.yml`, auto-loaded by `docker compose up`) — unrelated to the database, this is purely for hot-reloading your own code:
```yaml
volumes:
  - ./services/auth-service/src:/app/src   # your local folder, live-mounted into the container
  - /app/node_modules                       # anonymous volume, "protects" node_modules
```
A bind mount maps a folder on your **host machine** directly into the
container, so edits you make locally appear instantly inside the running
container (used here with `node --watch` for hot reload). The second line
is a common trick: without it, mounting your local `src` folder over `/app`
would also cover up the `node_modules` that got installed *during the image
build*, which usually don't exist (or don't match the container's OS) on
your host.

**The difference in one sentence:** a named volume is Docker-managed
storage you don't need to think about the location of (used for data that
must outlive the container); a bind mount is *your* folder, mapped in
directly (used for live-editing code during development). Never use a bind
mount for `pgdata` — you'd be relying on the host's exact filesystem/
permissions, which is fragile; the named volume approach is deliberately
portable across machines.

---

## 9. Debugging & troubleshooting

Real issues you'll actually hit, roughly in the order you're likely to hit
them, with the fastest way to confirm the cause and fix it.

### 9.1 "Failed to fetch" / `net::ERR_CONNECTION_TIMED_OUT` in the browser console

**Symptom:** frontend loads fine (port 3000 works), but Login/Register
fail, and DevTools → Network shows the `login`/`register` requests **and
their OPTIONS preflight** as `(failed) net::ERR_CONNECTION_TIMED_OUT`.

**What it means:** a *timeout* (not a fast rejection) means the request
never got a response from anything — not the app, not even an "I refuse
this" from a firewall. Packets are being silently dropped. This is almost
always one of:

1. **EC2 Security Group has no inbound rule for port 4000.** You opened
   3000 for the client but forgot 4000 for `api-gateway`. This is the most
   common cause, by far.
2. `api-gateway` container isn't running, or isn't actually publishing the
   port.
3. An OS-level firewall (`ufw`) on the EC2 box itself is blocking it.

**How to confirm and fix, in order:**
```bash
# 1. Is the container even up, with the port actually published?
docker ps
# PORTS column for api-gateway should show: 0.0.0.0:4000->4000/tcp
# If it's missing/empty/127.0.0.1-only -> container problem, not AWS. Re-check
# your `docker run ... -p 4000:4000 ...` command.

# 2. From INSIDE the EC2 box (SSH session), does the app itself respond?
curl http://localhost:4000/health
# Works here but not from your laptop -> it's a network/firewall issue, skip to step 3.
# Fails here too -> it's a container/app issue, not networking. Check `docker logs api-gateway`.

# 3. Check the EC2 Security Group (AWS Console -> EC2 -> your instance ->
#    Security tab -> the security group -> Inbound rules). Add, if missing:
#    Type: Custom TCP | Port: 4000 | Source: 0.0.0.0/0 (or your IP)

# 4. Check the OS firewall too, in case ufw is active:
sudo ufw status
sudo ufw allow 4000/tcp    # only needed if ufw shows "active"

# 5. Re-test from OUTSIDE the server (your own laptop), not just via SSH:
curl http://<EC2_PUBLIC_IP>:4000/health
```
Getting `{"status":"ok"}` (or similar) from step 5 means the network path
is fixed — go retry Register in the browser.

### 9.2 Register/Login "works" but request goes to the wrong host

**Symptom:** no timeout, but the request fails fast, or DevTools shows the
request URL is `http://localhost:4000/...` even though you're on EC2.

**What it means:** the client image was **built** before `VITE_API_BASE_URL`
was set correctly. Remember — Vite bakes this into the JS at build time,
not at container run time. Changing an env var on a running container does
nothing; the JS bundle is already compiled.

**How to confirm:** DevTools → Network → click the failed request → Headers
tab → look at the actual **Request URL**.

**Fix — rebuild, don't just restart:**
```bash
docker build -t client:1.0 \
  --build-arg VITE_API_BASE_URL=http://<EC2_PUBLIC_IP>:4000 \
  client/

docker stop client && docker rm client
docker run -d --name client -p 3000:80 client:1.0
```

### 9.3 `api-gateway` logs show `ECONNREFUSED` calling auth-service/todo-service

**Symptom:** `api-gateway` itself is reachable fine (no timeout from the
browser), but the response is a 502/500, and `docker logs api-gateway`
shows something like `connect ECONNREFUSED` for `auth-service:4001` or
`todo-service:4002`.

**What it means:** this is a container-to-container networking problem, not
a browser/firewall one — nothing on the host firewall matters here at all.
Almost always:

1. `auth-service` / `todo-service` isn't on the **same Docker network** as
   `api-gateway` (forgot `--network todo-net` on one of the `docker run`
   commands).
2. Wrong hostname/port in `AUTH_SERVICE_URL` / `TODO_SERVICE_URL` — must be
   the **container name** and **container port**, e.g.
   `http://auth-service:4001`, never `http://localhost:4001` and never a
   *published* host port.
3. `auth-service`/`todo-service` container crashed or never started.

**How to confirm and fix:**
```bash
docker network inspect todo-net
# Confirm all 5 containers are listed here. If one's missing, that
# container was run without --network todo-net - stop, remove, and
# re-run it with --network todo-net added.

docker ps -a
# Check auth-service/todo-service actually show "Up", not "Exited".
# If exited: docker logs auth-service   (or todo-service)
# Common cause: bad DATABASE_URL in that service's .env, so it crashed on startup.

# Confirm DNS + reachability directly, from inside api-gateway:
docker exec -it api-gateway sh
ping auth-service
curl http://auth-service:4001/health
```

### 9.4 `docker build` fails or the app crashes with "Cannot find module ..."

**Symptom:** works when you run the code directly with `node`/`npm run
dev`, but fails inside the container.

**What it means:** almost always the `.dockerignore` accidentally excluding
something needed, or a stale/half-built image being reused.

**Fix:**
```bash
# Rebuild with no cache, to rule out a stale layer:
docker build --no-cache -t auth-service:1.0 .

# Check nothing important is being excluded:
cat .dockerignore
```

### 9.5 auth-service / todo-service can't connect to `postgres`

**Symptom:** container starts, but crashes immediately or every DB query
fails with a connection error in `docker logs`.

**What it means:** this is a Docker-networking-and-credentials problem, not
an internet one — everything here happens over `todo-net`. Usual suspects,
roughly in order of likelihood:

1. **`auth-service`/`todo-service` started before `postgres` was actually
   ready to accept connections** — a container reporting "Up" isn't the
   same as Postgres being done initializing. This is exactly why
   `docker-compose.yml` uses `depends_on: postgres: condition:
   service_healthy` instead of a plain `depends_on: - postgres`. If you're
   running things manually (Section 5), you have to wait for
   `pg_isready` yourself before starting the app containers.
2. **`auth-service`/`todo-service` isn't on `todo-net`** — same rule as
   any other inter-container call; if it's not on the network, it can't
   resolve `postgres` as a hostname at all.
3. **Credentials don't match** — the service's `DATABASE_URL` username/
   password has to be identical to whatever `postgres` was actually
   initialized with (`POSTGRES_USER`/`POSTGRES_PASSWORD`). Remember these
   only take effect on a *brand-new, empty* volume — if you changed the
   password in `.env` but `pgdata` already existed from before, Postgres
   is still using the *old* password (see Section 5's "Postgres container
   authentication" for why).
4. **The `.env` file wasn't actually picked up** — check `--env-file .env`
   was included in the `docker run` command, or `env_file:` is set
   correctly in compose.

**Fix / verify:**
```bash
docker logs postgres | tail -20
# "database system is ready to accept connections" -> postgres itself is fine
# anything about FATAL/password -> credentials mismatch, see #3 above

docker exec -it auth-service sh
env | grep DATABASE_URL     # confirm the value actually made it into the container, and matches postgres's creds

# From inside auth-service's shell, or a fresh debug container on todo-net:
nc -zv postgres 5432        # confirms network reachability, separate from credentials
```
`nc` succeeding but the app still failing to authenticate narrows it to a
credentials mismatch specifically (#3), not networking.

### 9.6 Port already in use when running a container

**Symptom:** `docker run` fails immediately with something like
`Bind for 0.0.0.0:4000 failed: port is already allocated`.

**What it means:** either an old container from a previous attempt is still
holding that port, or something else on the EC2 box (e.g. a leftover PM2
process from the manual setup) is using it.

**Fix:**
```bash
docker ps -a | grep 4000        # find any container (running or stopped) using it
docker rm -f <container_name>   # force stop + remove it

# If nothing Docker-related shows up, something outside Docker owns the port:
sudo lsof -i :4000
```

### 9.7 Quick reference — one-liners worth memorizing

```bash
docker ps -a                          # every container, running or not, and why it exited
docker logs -f <name>                 # live logs - your first stop for almost anything
docker inspect <name>                 # full JSON: env vars, network, mounts, restart count
docker network inspect todo-net       # who's actually on the network, and their internal IPs
docker exec -it <name> sh             # get inside a running container to poke around
docker stats                          # live CPU/memory per container - useful if something's slow
docker exec -it postgres psql -U todo -d tododb   # jump straight into a SQL prompt on the DB
docker volume inspect pgdata          # confirm the data volume exists and see its real path on disk
```

---

## Suggested repo name

`mern-todo-docker` (used above) — short, matches the existing
`mern-todo-monorepo` naming, and immediately tells you what's different
about this copy.

Other reasonable options if you want something more course/portfolio-flavored:
- `learning-docker-mern-todo` — reads as a learning project first, todo app second
- `deploying-mern-with-docker` — leans into the deployment angle
- `mern-todo-containerized`
