# Testing Anti-Patterns

**Load this reference when:** writing or changing tests, adding mocks, or tempted to add test-only methods to production code.

## Overview

Tests must verify real behavior, not mock behavior. Mocks isolate; they are not the thing under test.

**Core principle:** Test what the code does, not what the mocks do.

**Following strict TDD prevents these anti-patterns.**

## The Iron Laws

```
1. NEVER test mock behavior
2. NEVER add test-only methods to production classes
3. NEVER mock without understanding dependencies
```

## Anti-Pattern 1: Testing Mock Behavior

**The violation:**

```python
# BAD: 只证明 mock 被调用
def test_install_calls_write(self):
    write = mock.Mock()
    install(write=write)
    write.assert_called()
```

**Why this is wrong:** 测的是 mock 存在，不是 install 改了什么。

**The fix:** 测真实结果（文件内容、返回值、抛错）。必须隔离外部命令时，不要断言 mock 被调用了几次，断言业务输出。

### Gate

```
BEFORE asserting on any mock:
  Ask: "Am I testing real behavior or just mock existence?"
  IF mock existence: STOP — delete the assertion or unmock
```

## Anti-Pattern 2: Test-Only Methods in Production

**The violation:** 给生产类加只给测试用的 `destroy()` / `_reset_for_test()`。

**The fix:** 清理放进测试工具或 `tearDown`，不要污染生产 API。

### Gate

```
BEFORE adding any method to production:
  Ask: "Is this only used by tests?"
  IF yes: STOP — put it in test utilities
```

## Anti-Pattern 3: Mocking Without Understanding

**The violation:** 把测试依赖的副作用（写配置、改文件）一并 mock 掉，导致断言永远过或永远挂。

**The fix:** 只 mock 真正慢/外部的一层（网络、注册表、真实 `taskkill`），保留测试需要的写盘或解析。

### Gate

```
BEFORE mocking:
  1. What side effects does the real method have?
  2. Does this test depend on any of them?
  3. If unsure: run against the real implementation first
```

## Anti-Pattern 4: Incomplete Mocks

**The violation:** 假数据只填眼前用到的字段，下游一读 `metadata` 就炸。

**The fix:** mock 必须镜像真实结构（完整配置 JSON、完整命令输出），不是「够这次 assert」。

## Anti-Pattern 5: Integration Tests as Afterthought

实现写完再补测 = 没做完。TDD：失败测试 → 最小实现 → 重构 → 才宣称完成。

## When Mocks Become Too Complex

- mock 设置比测试逻辑还长
- 为了让测试过把一切都 mock 掉
- 去掉 mock 测试就挂，却说不清为什么需要它

本仓优先：对纯函数直接测；对 CLI 用临时目录跑真实入口；对 `.ps1` / `.bat` 跑真实命令并检查输出。

## Quick Reference

| Anti-Pattern | Fix |
|--------------|-----|
| 断言 mock 被调用 | 测真实输出或别 mock |
| 生产类里的测试专用方法 | 挪到测试工具 |
| 不懂依赖就 mock | 先跑真实现，再最小隔离 |
| 残缺假数据 | 镜像真实结构 |
| 先写代码后补测 | 先红后绿 |
| mock 过于复杂 | 改成对真实入口的集成断言 |

## Red Flags

- 断言 `*_mock` / `assert_called` 当主证据
- 方法只在测试里被调用
- mock 设置超过测试一半
- 去掉 mock 就失败，却说不清原因
- 「先 mock 比较保险」
