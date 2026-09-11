# Skill Collection

这是一个 Cursor Agent Skill 集合仓库，用于沉淀可复用的执行流程。

## 已有技能

- `skills/java-package-jar/SKILL.md`  
  在服务器（或任意具备 Java 工具链的机器）上，按指定仓库与分支构建并产出 JAR 文件。

## 使用方式（给 Agent）

1. 在任务中明确引用目标技能（例如 `java-package-jar`）。
2. 提供必要输入（仓库 URL、分支等）。
3. 按 `SKILL.md` 的步骤执行；如需自动化，可调用同目录脚本。

## 新增技能约定

- 路径：`skills/<kebab-case-name>/SKILL.md`
- `SKILL.md` 顶部必须包含 YAML frontmatter（至少 `name`、`description`）
- 如有需要，可在技能目录下附带 `scripts/` 辅助脚本
