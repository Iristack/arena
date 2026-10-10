# PyTorch Operator 的新旧 PodGroup 后端

本改动只涉及 PyTorch Operator。Arena 仍提交 PyTorchJob，Operator 管理训练生命周期，
Volcano 负责调度；不转换为 VolcanoJob，也不改变 TF、MPI、ET 的行为。

控制器实现位于 [Iristack/pytorch-operator](https://github.com/Iristack/pytorch-operator)，
详见该仓库 `docs/podgroup-backends.md`。必须先构建并发布包含兼容修复的镜像，
旧镜像不认识 `--podgroup-backend`。默认 Chart 不增加任何新参数，也不更换镜像。

## 启用

保留现有安装配置，追加一个 values 文件：

```yaml
pytorch:
  # 示例地址：替换为实际构建并发布的镜像，建议使用 digest。
  imageOverride: your-registry.example/team/pytorch-operator:podgroup-compat
  gangScheduling:
    enabled: true
    podGroupBackend: volcano
    schedulerName: volcano
    podGroupRBAC: true
```

`imageOverride` 是完整镜像地址，不受 `global.imagePrefix` 和 VPC 镜像重写影响。
开启 gang 时必须显式提供它，避免把新参数传给默认的旧镜像。

确认实际 Helm release 名称后，用本分支的 Chart 升级已有 release：

```sh
helm list -n arena-system
# ARENA_RELEASE 填实际 release 名称；values-pytorch-volcano.yaml 为上面的配置。
helm upgrade "$ARENA_RELEASE" ./arena-artifacts -n arena-system \
  --reuse-values -f values-pytorch-volcano.yaml
kubectl -n arena-system rollout status deployment/pytorch-operator
```

如果原安装不是 Helm 管理，不要直接新增一个 Helm release 接管资源；沿用原有安装流程，
将渲染出的 PyTorch Deployment 参数、镜像和 RBAC 更新到原配置中。

旧集群设置 `podGroupBackend: legacy`，并填写实际 schedulerName。旧 Volcano 也可能
使用旧 API，不能只根据调度器名称推断后端。第一版不支持 auto，不会在 API 失败时回退。

Chart 只为启用的集成增加两组 PodGroup 的 get/create/update/delete 权限；同时授权
两组是为了识别升级前的任务，不会安装旧 CRD，也不授予 Queue 写权限。

## 已有任务与回滚

Operator 在 PyTorchJob 上持久化后端和 scheduler annotation。修改 Deployment 默认值
只影响未绑定的任务；有冲突的已有资源会产生 Event，而不是自动迁移。缺失 PodGroup 的
Pending Pod 只有在分组名和调度器一致时才补建。PodGroup 创建失败不会继续创建新 Pod。

若仅关闭新任务的 gang，设置 `enabled: false`，但保留修复镜像和 `podGroupRBAC: true`，
让已有绑定任务继续运行和清理。旧版 Operator 不认识记录的后端：回滚旧镜像前必须先结束
或显式迁移新 API 任务，不能直接按无感回滚处理。

先在独立测试环境验证，避免两个不同 Operator 同时监听同一批任务。分别验收单机和
多副本任务的 PodGroup owner/minMember、Pod 的 schedulerName/分组注解、实际节点绑定、
完成和清理。`minMember` 沿用 Master + Worker 总副本数，不表示运行期间最低副本保障。

## 本地 Chart 测试

依赖 Helm、Ruby 标准库 YAML 和 minitest：

```sh
ruby test/charts/pytorch_gang_test.rb
```

覆盖默认行为、新旧后端、完整镜像地址、RBAC 保留，以及无效/旧镜像配置拒绝。
控制器测试和镜像构建在 pytorch-operator 仓库运行；本 Chart 不证明集群调度已验收。
