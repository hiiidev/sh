#!/usr/bin/env bash
# First installation on a local Ubuntu/Debian amd64 host. Never used for upgrades.
set +x
set -Eeuo pipefail
umask 077
github_token=''

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
prompt() {
  local name=$1 label=$2 secret=${3:-false}
  if [[ $secret == true ]]; then
    IFS= read -r -s -p "$label" "${name?}" < /dev/tty
    printf '\n' > /dev/tty
  else
    IFS= read -r -p "$label" "${name?}" < /dev/tty
  fi
}
docker_local() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host unix:///var/run/docker.sock \
    --config "$temporary/docker" "$@"
}
github_get() {
  local url=$1 output=$2 accept=${3:-application/vnd.github+json}
  [[ $url == https://api.github.com/* ]] || fail '下载入口不属于GitHub API'
  # Credentials go through stdin, never argv, shell history or persistent gh auth.
  printf 'header = "Authorization: Bearer %s"\n' "$github_token" |
    curl --config - --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 \
      -H "Accept: $accept" -H 'X-GitHub-Api-Version: 2022-11-28' -o "$output" "$url"
}
download_asset() {
  local name=$1 entry url digest actual
  entry=$(jq -ce --arg name "$name" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else error("asset missing or duplicated") end' "$temporary/release-api.json")
  url=$(jq -r '.url' <<< "$entry")
  digest=$(jq -r '.digest' <<< "$entry")
  [[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || fail "$name 缺少附件摘要"
  github_get "$url" "$temporary/$name" application/octet-stream
  actual=$(sha256sum "$temporary/$name")
  [[ ${actual%% *} == "${digest#sha256:}" ]] || fail "$name 摘要不一致"
}
check_archive() {
  local name
  while IFS= read -r name; do
    case "$name" in
      deploy/README.md|deploy/compose.server.yaml|deploy/compose.worker.yaml|deploy/config/server.env.example|deploy/config/worker.env.example|deploy/config/updater.example.yaml|deploy/config/registry.example.yaml) ;;
      *) fail '部署归档包含非预期路径' ;;
    esac
  done < <(tar -tzf "$temporary/deploy-templates.tar.gz")
  # Refuse links before extraction, even if their member name is allowed.
  tar -tvzf "$temporary/deploy-templates.tar.gz" | awk 'substr($0,1,1) != "-" {bad=1} END {exit bad}' || fail '部署归档不是普通文件集合'
}
install_dependencies() {
  if ! command -v curl >/dev/null || ! command -v jq >/dev/null || ! command -v openssl >/dev/null; then
    apt-get update
    apt-get install -y ca-certificates curl jq openssl
  fi
  if ! command -v docker >/dev/null; then
    local package
    for package in docker.io podman-docker containerd runc; do
      if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
        fail "检测到 $package，请先人工确认现有容器运行环境"
      fi
    done
    [[ ! -e /etc/apt/sources.list.d/docker.sources && ! -e /etc/apt/sources.list.d/docker.list ]] || fail '已有Docker软件源，请先完成现有Docker安装'
    printf '正在通过Docker官方APT源安装Docker与Compose…\n'
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  docker_local info >/dev/null || fail '本机Docker不可用，请启动Docker后重试'
  docker_local compose version >/dev/null || fail '请先为现有Docker安装Compose插件'
}
check_existing() {
  local existing volume
  existing=$(docker_local ps -aq --filter "label=com.docker.compose.project=automation-$component")
  [[ -z $existing ]] || fail '已有该服务的Compose容器，不能作为首次安装覆盖'
  if [[ $component == worker ]]; then
    existing=$(docker_local ps -aq --filter 'name=^/automation-worker-1$')
    [[ -z $existing ]] || fail '已有automation-worker-1容器'
  fi
  volume="automation-server_database"
  [[ $component != worker ]] || volume="automation-worker_worker-state"
  existing=$(docker_local volume ls -q --filter "name=^${volume}$")
  [[ -z $existing ]] || fail '已有持久数据卷，请核对原部署；不能自动复用或清理'
}
install_updater() {
  local install_dir=$1 github_user=$2 node_id existing updater_image worker_image
  [[ -d $install_dir && ! -L $install_dir ]] || fail '请指定已有Worker安装目录'
  for file in compose.worker.yaml images.env release.json config/worker.env config/registry.yaml config/updater.yaml; do
    [[ -f $install_dir/$file && ! -L $install_dir/$file ]] || fail "Worker安装缺少普通文件：$file"
  done
  prompt node_id 'Worker节点ID（从管理端节点页复制）: '
  [[ $node_id =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || fail '节点ID必须为UUID'
  node_id=${node_id,,}
  updater_image=$(jq -er '.images.updater.digest' "$install_dir/release.json")
  worker_image=$(jq -er '.images.worker.digest' "$install_dir/release.json")
  [[ $worker_image =~ ^ghcr\.io/hiiidev/sky-worker@sha256:[a-f0-9]{64}$ && $updater_image =~ ^ghcr\.io/hiiidev/sky-updater@sha256:[a-f0-9]{64}$ ]] || fail '已有发布身份不属于本项目'
  docker_local compose --env-file "$install_dir/images.env" -f "$install_dir/compose.worker.yaml" --profile updater config --format json > "$temporary/compose-updater.json"
  jq -e --arg image "$updater_image" '.name == "automation-worker" and .services.updater.image == $image and .services.updater.command == ["--config", "/app/config/updater.yaml"] and ([.services.updater.volumes[] | select(.source == "worker-state" and .target == "/app/worker-states/worker" and .read_only == true)] | length == 1) and ([.services.updater.volumes[] | select(.source == "updater-state" and .target == "/app/updater-state")] | length == 1) and ([.services.updater.volumes[] | select(.source == "/var/run/docker.sock" and .target == "/var/run/docker.sock")] | length == 1)' "$temporary/compose-updater.json" >/dev/null || fail 'Updater Compose镜像、命令或挂载与标准安装不一致'
  # Read only public container metadata; never dump inspect Env or node_token.
  docker_local inspect --format '{"image":{{json .Config.Image}},"running":{{json .State.Running}},"health":{{json .State.Health.Status}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"mounts":{{json .Mounts}}}' \
    automation-worker-1 > "$temporary/worker-inspect.json"
  jq -e --arg image "$worker_image" '.image == $image and .running == true and .health == "healthy" and .project == "automation-worker" and .service == "worker" and ([.mounts[] | select(.Destination == "/app/runtime" and .Type == "volume" and .Name == "automation-worker_worker-state")] | length == 1)' "$temporary/worker-inspect.json" >/dev/null || fail '运行中的Worker镜像、健康或状态卷与标准安装不一致'
  existing=$(docker_local ps -aq --filter label=com.docker.compose.project=automation-worker --filter label=com.docker.compose.service=updater)
  [[ -z $existing ]] || fail '已有Updater容器，不能覆盖或重新创建'
  existing=$(docker_local volume ls -q --filter 'name=^automation-worker_updater-state$')
  [[ -z $existing ]] || fail '已有Updater状态卷，请先核对原Updater与恢复状态'
  grep -q '^worker_token: replace-with-server-worker-token$' "$install_dir/config/updater.yaml" || fail 'Updater配置已被编辑，请按现有配置流程处理'
  # Capture only the required bootstrap credential privately; never output it.
  docker_local exec automation-worker-1 node --input-type=module -e '
    import {readFileSync} from "node:fs";
    const r=await fetch("http://127.0.0.1:"+(process.env.HEALTH_PORT??"8092"));
    if(!r.ok || (await r.json()).registered!==true)throw Error("worker_not_registered");
    const identity=JSON.parse(readFileSync(process.env.STATE_DIR+"/identity.json","utf8"));
    console.log(JSON.stringify({node_id:identity.node_id,control_url:process.env.CONTROL_URL,worker_token:process.env.WORKER_TOKEN}));
  ' > "$temporary/worker-runtime.json"
  jq -e --arg id "$node_id" '.node_id == $id and (.control_url | test("^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$")) and (.worker_token | test("^[A-Za-z0-9._~+/=-]{32,}$"))' "$temporary/worker-runtime.json" >/dev/null || fail '节点ID与本机已注册Worker不一致，或运行配置不合法'
  # Parse the accepted runtime values without evaluating env or YAML as shell code.
  local control_url worker_token
  control_url=$(jq -er '.control_url' "$temporary/worker-runtime.json")
  worker_token=$(jq -er '.worker_token' "$temporary/worker-runtime.json")
  printf 'control_url: "%s"\nworker_token: "%s"\nstate_dir: /app/updater-state\nproject: automation-worker\nnodes:\n  "%s": automation-worker-1\nworker_state_dirs:\n  "%s": /app/worker-states/worker\nimage_repository: ghcr.io/hiiidev/sky-worker\n' "$control_url" "$worker_token" "$node_id" "$node_id" > "$temporary/updater.yaml"
  unset worker_token
  printf '%s' "$github_token" | docker_local login ghcr.io --username "$github_user" --password-stdin
  docker_local pull --platform linux/amd64 "$updater_image"
  # Existing registry credentials stay unchanged; the entered token is temporary.
  unset github_token
  existing=$(docker_local ps -aq --filter label=com.docker.compose.project=automation-worker --filter label=com.docker.compose.service=updater)
  [[ -z $existing ]] || fail '准备过程中已有Updater启动，停止本次配置'
  install -m 600 "$temporary/updater.yaml" "$install_dir/config/updater.yaml"
  cd "$install_dir"
  docker_local compose --env-file images.env -f compose.worker.yaml --profile updater up -d \
    --no-deps --no-build --pull never --wait --wait-timeout 60 updater
  docker_local compose --env-file images.env -f compose.worker.yaml --profile updater ps updater
  printf '\nUpdater容器已启动，Worker节点：%s。请在管理端确认Updater关联及在线状态。\n' "$node_id"
}
main() {
  local release_tag='' install_dir='' choice github_user
  local admin_user admin_password confirm_password control_url worker_token
  local server_image worker_image updater_image selected_image database_password admin_hash
  while (($#)); do
    case "$1" in
      --release) [[ $# -ge 2 && -n $2 ]] || fail '--release 缺少值'; release_tag=$2; shift 2 ;;
      --dir) [[ $# -ge 2 ]] || fail '--dir 缺少值'; install_dir=$2; shift 2 ;;
      --help) printf '用法：sudo bash install.sh [--release release-标签] [--dir /绝对安装目录]\n'; return ;;
      *) fail "未知参数：$1" ;;
    esac
  done
  [[ $EUID -eq 0 ]] || fail '请使用root或sudo运行'
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail '当前发布仅支持Linux amd64/x86_64'
  # shellcheck disable=SC1091
  source /etc/os-release
  case "$ID:$VERSION_ID" in ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ;; *) fail '支持Ubuntu 22.04/24.04/26.04、Debian 12/13' ;; esac
  [[ -z $release_tag || $release_tag =~ ^release-[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail '发布标签不合法'

  prompt github_token 'GitHub PAT classic（首次下载需repo，拉镜像需read:packages）: ' true
  [[ $github_token =~ ^[A-Za-z0-9_]+$ ]] || fail 'Token为空或格式不正确'
  prompt github_user 'Token所属GitHub用户名 [hiiidev]: '
  github_user=${github_user:-hiiidev}
  [[ $github_user =~ ^[A-Za-z0-9-]+$ ]] || fail 'GitHub用户名不合法'
  prompt choice '安装服务：1) Server  2) Worker  3) 已有Worker配置Updater [1]: '
  case "${choice:-1}" in 1|server) component=server ;; 2|worker) component=worker ;; 3|updater) component=updater ;; *) fail '请选择1、2或3' ;; esac
  if [[ $component == updater ]]; then
    install_dir=${install_dir:-/opt/sky/worker}
  else
    install_dir=${install_dir:-/opt/sky/$component}
  fi
  [[ $install_dir == /* && $install_dir != / && $install_dir != *$'\n'* ]] || fail '安装目录必须是绝对路径'
  [[ ! -L $install_dir ]] || fail '安装目录不能是符号链接'
  if [[ $component != updater && -e $install_dir ]]; then
    [[ -d $install_dir && -z $(find "$install_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail '安装目录非空，请选择一个新的空目录'
  fi

  if [[ $component == server ]]; then
    prompt admin_user '管理员用户名 [admin]: '
    admin_user=${admin_user:-admin}
    [[ $admin_user =~ ^[A-Za-z0-9_.@-]{1,100}$ ]] || fail '管理员用户名格式不合法'
    prompt admin_password '管理员密码（12–72字节）: ' true
    prompt confirm_password '再次输入管理员密码: ' true
    [[ $admin_password == "$confirm_password" ]] || fail '两次密码不一致'
    [[ $(LC_ALL=C printf %s "$admin_password" | wc -c) -ge 12 && $(LC_ALL=C printf %s "$admin_password" | wc -c) -le 72 ]] || fail '管理员密码需12–72字节'
    unset confirm_password
  elif [[ $component == worker ]]; then
    prompt control_url 'Server地址（例如https://sky.example.com）: '
    [[ $control_url =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] || fail '请输入HTTPS域名地址，不带API路径、账号或查询参数'
    control_url=${control_url%/}
    prompt worker_token 'WORKER_TOKEN（与Server一致，至少32字符）: ' true
    [[ $worker_token =~ ^[A-Za-z0-9._~+/=-]{32,}$ ]] || fail 'WORKER_TOKEN至少32字符，只接受字母、数字及._~+/=-'
  fi

  temporary=$(mktemp -d /tmp/install-deploy.XXXXXXXX)
  trap 'unset github_token admin_password worker_token database_password; rm -rf -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -m 700 "$temporary/docker"
  printf '{}\n' > "$temporary/docker/config.json"
  install_dependencies
  if [[ $component == updater ]]; then
    install_updater "$install_dir" "$github_user"
    return
  fi
  check_existing

  if [[ -z $release_tag ]]; then
    printf '查询GitHub最新正式Release…\n'
    github_get 'https://api.github.com/repos/hiiidev/sky/releases/latest' "$temporary/release-api.json"
    jq -e '.draft == false and .prerelease == false' "$temporary/release-api.json" >/dev/null || fail '最新Release不是正式发布'
    release_tag=$(jq -er '.tag_name' "$temporary/release-api.json")
    [[ $release_tag =~ ^release-[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail '最新Release标签不合法'
  else
    github_get "https://api.github.com/repos/hiiidev/sky/releases/tags/$release_tag" "$temporary/release-api.json"
  fi
  jq -e --arg tag "$release_tag" '.tag_name == $tag and .draft == false' "$temporary/release-api.json" >/dev/null || fail '发布标签不匹配'
  printf '下载并校验发布 %s 的部署附件…\n' "$release_tag"
  for asset in deploy-templates.tar.gz images.env release.json; do download_asset "$asset"; done
  check_archive
  tar -xzf "$temporary/deploy-templates.tar.gz" -C "$temporary" --no-same-owner --no-same-permissions
  jq -e --arg tag "$release_tag" '.tag == $tag and .architecture == "amd64" and (.source_commit | test("^[a-f0-9]{40}$"))' "$temporary/release.json" >/dev/null || fail '发布身份不正确'
  server_image=$(jq -er '.images.server.digest' "$temporary/release.json")
  worker_image=$(jq -er '.images.worker.digest' "$temporary/release.json")
  updater_image=$(jq -er '.images.updater.digest' "$temporary/release.json")
  [[ $server_image =~ ^ghcr\.io/hiiidev/sky-server@sha256:[a-f0-9]{64}$ && $worker_image =~ ^ghcr\.io/hiiidev/sky-worker@sha256:[a-f0-9]{64}$ && $updater_image =~ ^ghcr\.io/hiiidev/sky-updater@sha256:[a-f0-9]{64}$ ]] || fail '镜像不属于本项目的不可变发布'
  printf 'SERVER_IMAGE=%s\nWORKER_IMAGE=%s\nUPDATER_IMAGE=%s\n' "$server_image" "$worker_image" "$updater_image" > "$temporary/verified-images.env"
  cmp -s "$temporary/verified-images.env" "$temporary/images.env" || fail '镜像附件与发布身份不一致'
  printf '%s' "$github_token" | docker_local login ghcr.io --username "$github_user" --password-stdin
  selected_image=$server_image
  [[ $component != worker ]] || selected_image=$worker_image
  docker_local pull --platform linux/amd64 "$selected_image"

  if [[ $component == server ]]; then
    admin_hash=$(printf '%s\n' "$admin_password" | docker_local run --rm -i "$server_image" hash-password)
    unset admin_password
    [[ $admin_hash =~ ^\$2[aby]\$12\$[./A-Za-z0-9]{53}$ ]] || fail '管理员密码哈希生成失败'
    database_password=$(openssl rand -hex 32)
    worker_token=$(openssl rand -hex 32)
    docker_local pull postgres:18@sha256:3a82e1f56c8f0f5616a11103ac3d47e632c3938698946a7ad26da0df1334744a
  fi
  # Recheck immediately before writing configuration or starting services.
  check_existing
  if [[ -e $install_dir ]]; then
    [[ ! -L $install_dir && -d $install_dir && -z $(find "$install_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail '安装目录在准备过程中发生变化，请核对后重试'
  fi
  mkdir -p "$install_dir/config" "$install_dir/secrets"
  chmod 700 "$install_dir" "$install_dir/config" "$install_dir/secrets"
  cp "$temporary/deploy/compose.$component.yaml" "$install_dir/"
  cp "$temporary/verified-images.env" "$install_dir/images.env"
  cp "$temporary/release.json" "$install_dir/release.json"
  printf 'username: %s\ntoken: %s\nrepositories:\n  - ghcr.io/hiiidev/sky-server\n  - ghcr.io/hiiidev/sky-worker\n  - ghcr.io/hiiidev/sky-updater\n' "$github_user" "$github_token" > "$install_dir/config/registry.yaml"
  chmod 600 "$install_dir/config/registry.yaml"
  chown 10001:10001 "$install_dir/config/registry.yaml"
  unset github_token
  local services=(worker)
  if [[ $component == server ]]; then
    printf '%s\n' "$database_password" > "$install_dir/secrets/database_password"
    printf '%s\n' "$worker_token" > "$install_dir/secrets/worker_token"
    printf "LISTEN=0.0.0.0:8090\nDATABASE_URL='postgres://app:%s@db:5432/app?sslmode=disable'\nADMIN_USERNAME='%s'\nADMIN_PASSWORD_HASH='%s'\nWORKER_TOKEN='%s'\n" "$database_password" "$admin_user" "$admin_hash" "$worker_token" > "$install_dir/config/server.env"
    services=(db server)
  else
    cp "$temporary/deploy/config/updater.example.yaml" "$install_dir/config/updater.yaml"
    printf "CONTROL_URL='%s'\nWORKER_TOKEN='%s'\nSTATE_DIR=/app/runtime\nHEALTH_PORT=8092\nCAMOUFOX_EXECUTABLE=/app/browser/camoufox-bin\nCAMOUFOX_HEADLESS=true\n" "$control_url" "$worker_token" > "$install_dir/config/worker.env"
  fi
  unset worker_token database_password
  cd "$install_dir"
  docker_local compose --env-file images.env -f "compose.$component.yaml" up -d \
    --no-build --pull never --wait --wait-timeout 240 "${services[@]}"
  docker_local compose --env-file images.env -f "compose.$component.yaml" ps "${services[@]}"
  printf '\n%s安装成功，目录：%s\n' "$component" "$install_dir"
  if [[ $component == server ]]; then
    printf '本机入口：http://127.0.0.1:8090，请通过HTTPS反向代理访问管理端。\nWORKER_TOKEN已保存至 secrets/worker_token，安装Worker时使用该值。\n'
  else
    printf 'Worker已启动。登记后再次运行安装脚本，选择3并输入本机Worker节点ID，即可配置Updater。\n'
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
