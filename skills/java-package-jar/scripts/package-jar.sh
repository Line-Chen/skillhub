#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  package-jar.sh --repo-url <url> [选项]

必填参数:
  --repo-url <url>           Git 仓库地址（HTTPS 或 SSH）

可选参数:
  --branch <name>            分支名（默认: 仓库默认分支）
  --build-tool <auto|maven|gradle>
                             构建工具（默认: auto）
  --module-path <path>       多模块子项目路径
  --outdir <path>            JAR 输出目录（默认: ./out）
  --jdk-version <version>    JDK 版本提示（如 8/11/17）
  --workdir <path>           指定工作目录（默认: 自动创建临时目录）
  --keep-workdir             保留克隆工作目录用于排查
  --help                     显示帮助
EOF
}

error() {
  echo "[错误] $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || error "缺少命令: $cmd"
}

REPO_URL=""
BRANCH=""
BUILD_TOOL="auto"
MODULE_PATH=""
OUTDIR="./out"
JDK_VERSION=""
WORKDIR=""
KEEP_WORKDIR="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --build-tool)
      BUILD_TOOL="${2:-}"
      shift 2
      ;;
    --module-path)
      MODULE_PATH="${2:-}"
      shift 2
      ;;
    --outdir)
      OUTDIR="${2:-}"
      shift 2
      ;;
    --jdk-version)
      JDK_VERSION="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR="true"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      error "未知参数: $1"
      ;;
  esac
done

[[ -n "$REPO_URL" ]] || {
  usage
  error "必须提供 --repo-url"
}

case "$BUILD_TOOL" in
  auto|maven|gradle) ;;
  *)
    error "--build-tool 仅支持: auto|maven|gradle"
    ;;
esac

require_cmd git
require_cmd java

if [[ -n "$JDK_VERSION" ]]; then
  echo "[提示] 期望 JDK 版本: $JDK_VERSION（请确认服务器已切换到该版本）"
fi

CREATED_WORKDIR="false"
if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d /tmp/java-jar-build-XXXXXX)"
  CREATED_WORKDIR="true"
else
  mkdir -p "$WORKDIR"
fi

cleanup() {
  if [[ "$CREATED_WORKDIR" == "true" && "$KEEP_WORKDIR" != "true" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

CLONE_DIR="$WORKDIR/repo"
echo "[信息] 工作目录: $WORKDIR"
echo "[信息] 开始克隆仓库: $REPO_URL"

if [[ -n "$BRANCH" ]]; then
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$CLONE_DIR" \
    || error "克隆失败，请检查仓库地址、分支或凭据"
else
  git clone --depth 1 "$REPO_URL" "$CLONE_DIR" \
    || error "克隆失败，请检查仓库地址或凭据"
fi

PROJECT_DIR="$CLONE_DIR"
if [[ -n "$MODULE_PATH" ]]; then
  PROJECT_DIR="$CLONE_DIR/$MODULE_PATH"
fi
[[ -d "$PROJECT_DIR" ]] || error "模块路径不存在: $PROJECT_DIR"

SELECTED_TOOL="$BUILD_TOOL"
if [[ "$SELECTED_TOOL" == "auto" ]]; then
  if [[ -f "$PROJECT_DIR/pom.xml" ]]; then
    SELECTED_TOOL="maven"
  elif [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then
    SELECTED_TOOL="gradle"
  else
    error "未检测到 Maven/Gradle 构建文件（pom.xml/build.gradle/build.gradle.kts）"
  fi
fi

echo "[信息] 使用构建工具: $SELECTED_TOOL"

if [[ "$SELECTED_TOOL" == "maven" ]]; then
  require_cmd mvn
  (
    cd "$PROJECT_DIR"
    mvn -DskipTests package
  ) || error "Maven 打包失败，请检查编译日志"
else
  if [[ -x "$PROJECT_DIR/gradlew" ]]; then
    GRADLE_CMD=("$PROJECT_DIR/gradlew")
  else
    require_cmd gradle
    GRADLE_CMD=("gradle")
  fi

  IS_SPRING_BOOT="false"
  if [[ -f "$PROJECT_DIR/build.gradle" ]] && grep -Eq "org\.springframework\.boot|spring-boot" "$PROJECT_DIR/build.gradle"; then
    IS_SPRING_BOOT="true"
  fi
  if [[ -f "$PROJECT_DIR/build.gradle.kts" ]] && grep -Eq "org\.springframework\.boot|spring-boot" "$PROJECT_DIR/build.gradle.kts"; then
    IS_SPRING_BOOT="true"
  fi

  if [[ "$IS_SPRING_BOOT" == "true" ]]; then
    (
      cd "$PROJECT_DIR"
      "${GRADLE_CMD[@]}" --no-daemon bootJar
    ) || (
      cd "$PROJECT_DIR"
      "${GRADLE_CMD[@]}" --no-daemon assemble
    ) || error "Gradle 打包失败（bootJar/assemble）"
  else
    (
      cd "$PROJECT_DIR"
      "${GRADLE_CMD[@]}" --no-daemon jar
    ) || (
      cd "$PROJECT_DIR"
      "${GRADLE_CMD[@]}" --no-daemon assemble
    ) || error "Gradle 打包失败（jar/assemble）"
  fi
fi

mapfile -t ALL_JARS < <(
  {
    find "$PROJECT_DIR/target" -maxdepth 1 -type f -name "*.jar" 2>/dev/null || true
    find "$PROJECT_DIR/build/libs" -maxdepth 1 -type f -name "*.jar" 2>/dev/null || true
  } | sort -u
)

[[ "${#ALL_JARS[@]}" -gt 0 ]] || error "构建完成但未找到 JAR（target/ 或 build/libs/）"

FILTERED_JARS=()
for jar in "${ALL_JARS[@]}"; do
  base="$(basename "$jar")"
  if [[ "$base" == *-sources.jar || "$base" == *-javadoc.jar || "$base" == *-plain.jar ]]; then
    continue
  fi
  FILTERED_JARS+=("$jar")
done

if [[ "${#FILTERED_JARS[@]}" -eq 0 ]]; then
  FILTERED_JARS=("${ALL_JARS[@]}")
fi

SELECTED_JAR=""
MAX_SIZE="-1"
for jar in "${FILTERED_JARS[@]}"; do
  size="$(stat -c%s "$jar" 2>/dev/null || echo 0)"
  if (( size > MAX_SIZE )); then
    MAX_SIZE="$size"
    SELECTED_JAR="$jar"
  fi
done

[[ -n "$SELECTED_JAR" ]] || error "未能确定最终 JAR 文件"

mkdir -p "$OUTDIR"
OUTDIR_ABS="$(cd "$OUTDIR" && pwd)"
FINAL_JAR="$OUTDIR_ABS/$(basename "$SELECTED_JAR")"
cp "$SELECTED_JAR" "$FINAL_JAR"

echo "[成功] 仓库: $REPO_URL"
if [[ -n "$BRANCH" ]]; then
  echo "[成功] 分支: $BRANCH"
else
  echo "[成功] 分支: <默认分支>"
fi
echo "[成功] 构建工具: $SELECTED_TOOL"
echo "[成功] JAR 路径: $FINAL_JAR"

if [[ "$CREATED_WORKDIR" == "true" && "$KEEP_WORKDIR" == "true" ]]; then
  echo "[提示] 已保留工作目录: $WORKDIR"
fi
