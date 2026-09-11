---
name: java-package-jar
description: 当用户要求在服务器或任意具备 Java 工具链的机器上，将指定 Git 仓库与分支打包为可交付 JAR 文件时使用。
---

# Java 项目打包 JAR（仓库 + 分支）

## 适用场景
- 用户明确要求：在某台服务器上，拉取指定 Java 仓库/分支并输出 JAR。
- 需要一个可复用、可审计的标准打包流程（而非只针对某个私有项目的一次性脚本）。

## 输入参数
请先向用户确认或从上下文提取以下输入：

1. **仓库 URL（必填）**
   - 支持 HTTPS/SSH，例如：
     - `https://github.com/example/demo.git`
     - `git@github.com:example/demo.git`
2. **分支名（可选）**
   - 为空时使用仓库默认分支。
3. **构建工具覆盖（可选）**
   - `auto`（默认）/ `maven` / `gradle`
4. **模块或子项目路径（可选）**
   - 多模块场景下，指定如 `service-a`、`backend/app`。
5. **JAR 输出目录（可选）**
   - 默认输出到当前目录下 `./out`。
6. **JDK 版本提示（可选）**
   - 如 `8`、`11`、`17`。仅用于选择正确 JDK 环境，不写死版本。

> 认证说明：使用服务器上**已可用**的 Git 凭据（如 deploy key、已登录凭据或 token），不要在技能中硬编码凭据。

## 标准执行步骤

### 1) 检查服务器前置条件
至少需要：`git`、`java`，以及 `mvn` 或 `gradle`（若项目自带 `gradlew` 优先用 Wrapper）。

```bash
git --version
java -version
mvn -version || true
gradle -version || true
```

若用户提供了 JDK 版本提示，先切换到对应 JDK（方式依服务器而定，例如 `sdkman`、`jenv` 或系统预装路径）。

### 2) 准备干净工作目录并拉取仓库（优先浅克隆）
```bash
WORKDIR="$(mktemp -d /tmp/java-jar-build-XXXXXX)"
cd "$WORKDIR"
```

- 指定分支时：
```bash
git clone --depth 1 --branch "<branch>" "<repo_url>" repo
```

- 未指定分支时（默认分支）：
```bash
git clone --depth 1 "<repo_url>" repo
```

进入代码目录（如有子模块路径再下钻）：
```bash
cd repo
cd "<module_path>"   # 仅在用户提供 module_path 时执行
```

### 3) 自动识别构建系统（或使用用户覆盖）
默认规则：
- 存在 `pom.xml` → Maven
- 存在 `build.gradle` 或 `build.gradle.kts` → Gradle
- 都不存在 → 明确失败并告知“无法识别 Java 构建系统”

示例判断：
```bash
if [[ -f pom.xml ]]; then
  TOOL="maven"
elif [[ -f build.gradle || -f build.gradle.kts ]]; then
  TOOL="gradle"
else
  echo "错误：未发现 pom.xml/build.gradle/build.gradle.kts，无法打包 JAR" >&2
  exit 1
fi
```

### 4) 执行生产打包

#### Maven
```bash
mvn -DskipTests package
```

#### Gradle
优先判断是否 Spring Boot 项目：若构建脚本含 `org.springframework.boot`，优先 `bootJar`；否则走 `jar` 或 `assemble`。

```bash
GRADLE_CMD="./gradlew"
[[ -x "$GRADLE_CMD" ]] || GRADLE_CMD="gradle"

if rg -n "org\.springframework\.boot" build.gradle build.gradle.kts >/dev/null 2>&1; then
  "$GRADLE_CMD" --no-daemon bootJar
else
  "$GRADLE_CMD" --no-daemon jar || "$GRADLE_CMD" --no-daemon assemble
fi
```

### 5) 定位并选择最终 JAR
在以下目录中查找：
- Maven：`target/`
- Gradle：`build/libs/`

当有多个 JAR 时，优先选择**非** `-sources` / `-javadoc` / `-plain` 的产物。

示例筛选：
```bash
find target build/libs -maxdepth 1 -type f -name "*.jar" 2>/dev/null \
  | rg -v "(-sources|-javadoc|-plain)\.jar$" \
  | sort
```

若筛选后仍有多个，优先体积更大的主产物或由用户指定目标模块。

### 6) 输出交付物（复制到输出目录并明确回报路径）
```bash
OUTDIR="${OUTDIR:-$PWD/out}"
mkdir -p "$OUTDIR"
cp "<selected_jar_path>" "$OUTDIR/"
echo "JAR 已生成：$OUTDIR/$(basename "<selected_jar_path>")"
```

在最终回复中必须明确：
- 使用的仓库 URL 与分支
- 使用的构建工具（Maven/Gradle）
- 最终 JAR 的绝对路径

### 7) 清理临时目录
完成后删除临时克隆目录，避免占用磁盘：
```bash
rm -rf "$WORKDIR"
```

如需排查问题，可暂时保留目录并在报告里说明保留路径。

## 错误处理与排查指引
- **缺少工具**：`git/java/mvn/gradle` 不存在  
  - 处理：安装工具或切换到已有工具链的机器；在报告中注明缺失项。
- **分支不存在或无权限**：`git clone --branch` 失败  
  - 处理：核对分支名、仓库 URL、服务器凭据（deploy key/token/SSH key）。
- **构建失败**：依赖下载失败、编译报错、测试插件问题  
  - 处理：优先保留关键错误日志（最后 100~200 行），标注失败阶段（依赖解析/编译/打包）。
- **找不到 JAR**：构建成功但无可交付文件  
  - 处理：检查模块路径是否正确、构建任务是否执行了 `package/jar/bootJar/assemble`、是否被自定义输出路径改写。

## 推荐：使用同目录辅助脚本
本技能可配套执行：

```bash
bash skills/java-package-jar/scripts/package-jar.sh \
  --repo-url "<repo_url>" \
  --branch "<branch>" \
  --build-tool auto \
  --module-path "<module_path>" \
  --outdir "<outdir>" \
  --jdk-version "<jdk_hint>"
```

最少参数示例：
```bash
bash skills/java-package-jar/scripts/package-jar.sh --repo-url "https://github.com/example/demo.git"
```
