# kubectl 常用命令速查

适用于本集群（BirenTech GPU + Kylin V10 + k8s 1.25.x）。

---

## 节点与集群状态

```bash
# 查看所有节点状态
kubectl get nodes -o wide

# 查看节点标签（GPU 标签、角色等）
kubectl get nodes --show-labels

# 查看节点详情（资源、事件、条件、已分配情况）
kubectl describe node <node-name>
```

---

## GPU 资源

```bash
# 所有节点的 GPU 可分配量
kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,ALLOCATABLE:.status.allocatable.birentech\.com/gpu,CAPACITY:.status.capacity.birentech\.com/gpu'

# 单节点可分配 GPU 数
kubectl get node <node-name> -o jsonpath='{.status.allocatable.birentech\.com/gpu}'

# 节点 GPU Capacity / Allocatable / 已分配请求量（快速一览）
kubectl describe nodes | grep -E "Name:|birentech"

# 列出当前所有占用 GPU 的 Pod
kubectl get pods -A -o json | python3 -c "
import json, sys
pods = json.load(sys.stdin)['items']
for p in pods:
    node = p['spec'].get('nodeName','')
    for c in p['spec'].get('containers',[]):
        gpu = c.get('resources',{}).get('limits',{}).get('birentech.com/gpu')
        if gpu:
            print(f\"{p['metadata']['namespace']}/{p['metadata']['name']}  node={node}  gpu={gpu}\")
"
```

> **计算剩余可用 GPU**：`Allocatable - Requests` 即为当前可调度量。`kubectl describe node <name>` 输出的 `Allocated resources` 段会直接展示已用 / 总量。

---

## Pod 管理

```bash
# 查看所有命名空间的 Pod（含节点和 IP）
kubectl get pods -A -o wide

# 查看指定命名空间的 Pod
kubectl get pods -n <namespace>

# 查看 Pod 详情（事件、挂载、资源请求）
kubectl describe pod <pod-name> [-n <namespace>]

# 查看 Pod 日志
kubectl logs <pod-name> [-n <namespace>]
kubectl logs <pod-name> -c <container-name>   # 多容器时指定容器
kubectl logs -f <pod-name>                    # 实时跟踪

# 进入 Pod 执行命令
kubectl exec -it <pod-name> -- bash
kubectl exec -it <pod-name> -n <namespace> -- bash

# 删除 Pod
kubectl delete pod <pod-name> [-n <namespace>]
kubectl delete pod <pod-name> --grace-period=0   # 强制立即删除
```

---

## 部署 / 应用 YAML

```bash
# 应用配置（创建或更新）
kubectl apply -f <file.yaml>

# 删除配置中定义的资源
kubectl delete -f <file.yaml>

# 预览将要执行的变更（不实际执行）
kubectl apply -f <file.yaml> --dry-run=client
```

---

## BirenTech Device Plugin

```bash
# 查看 device plugin Pod 状态
kubectl get pods -n biren-gpu -o wide

# 查看 device plugin 日志（GPU 分配 / 释放事件）
kubectl logs -n biren-gpu <biren-device-plugin-pod-name>

# 重启 device plugin（GPU 驱动重载后需要）
kubectl rollout restart daemonset/biren-device-plugin-daemonset -n biren-gpu
kubectl rollout status  daemonset/biren-device-plugin-daemonset -n biren-gpu
```

---

## 集群组件状态

```bash
# 查看系统组件 Pod（apiserver、etcd、coredns、flannel 等）
kubectl get pods -n kube-system -o wide

# 查看集群事件（按时间倒序，便于排查问题）
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# 查看节点事件
kubectl get events --field-selector involvedObject.name=<node-name>
```

---

## 节点算力角色管理

```bash
# 查看节点污点（taint）
kubectl get node <node-name> -o jsonpath='{.spec.taints}'

# 手动打 / 删 GPU 标签
kubectl label node <node-name> birentech.com=gpu
kubectl label node <node-name> birentech.com-          # 删除标签

# 去除 control-plane 隔离污点（允许调度业务 Pod）
kubectl taint node <node-name> node-role.kubernetes.io/control-plane:NoSchedule-

# 恢复 control-plane 隔离
kubectl taint node <node-name> node-role.kubernetes.io/control-plane:NoSchedule
```

> 也可直接使用 `setup/kubernets/set-node-mode.sh <cpu|biren|none>` 脚本批量操作。
> 加 `--vgpu`（仅 biren）部署 HAMi-Biren 统一插件，用同一套插件同时调度
> 整卡 + SVI(1/2、1/4) + vGPU 软切分：`sudo ./set-node-mode.sh biren --vgpu`。

---

## 私有 Registry

```bash
# 查看 Registry 中所有仓库
curl http://<master-ip>:32000/v2/_catalog

# 查看某仓库的 tag 列表
curl http://<master-ip>:32000/v2/<namespace>/<image>/tags/list

# 查看 Registry Pod 状态
kubectl get pods -n kube-system -l app=registry
```

---

## 常用排查

```bash
# Pod 一直 Pending：查看调度失败原因
kubectl describe pod <pod-name> | grep -A10 Events

# Pod CrashLoopBackOff：查看上一次崩溃的日志
kubectl logs <pod-name> --previous

# 节点 NotReady：查看 kubelet 状态
# （在对应节点上执行）
systemctl status kubelet
journalctl -u kubelet -n 50 --no-pager

# 查看集群版本信息
kubectl version --short
```
