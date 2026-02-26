#!/bin/bash
# check-agents.sh - Monitor running agents
# Skill: dev-team

set -e

# 引入公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/utils.sh" ]]; then
    source "$SCRIPT_DIR/utils.sh"
else
    # 回退：定义基础函数
    get_root_dir() { echo "$(dirname "$(dirname "$SCRIPT_DIR")")"; }
fi

SKILL_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
REPOS_BASE_DIR="$(dirname "$SKILL_DIR")"
TASKS_FILE="$SKILL_DIR/active-tasks.json"
TASKS_LOCK_DIR="$(get_tasks_lock_dir)"
NOTIFY_FILE="$SKILL_DIR/notifications.json"
AUTO_CLEANUP_ON_CHECK=true
AUTO_PRUNE_ON_CHECK=true
AUTO_PRUNE_QUEUE_ON_CHECK=true
trap 'release_file_lock "$TASKS_LOCK_DIR"' EXIT

# 从配置文件读取重试设置
MAX_RETRIES=3
RETRY_DELAY=60
AUTO_MERGE_DEFAULT=0
if [[ -f "$SKILL_DIR/config/user.json" ]]; then
    CONFIG_RETRY=$(python3 -c "import json; print(json.load(open('$SKILL_DIR/config/user.json')).get('retry', {}).get('maxAttempts', 3))" 2>/dev/null)
    [[ -n "$CONFIG_RETRY" ]] && MAX_RETRIES=$CONFIG_RETRY
    CONFIG_RETRY_DELAY=$(python3 -c "import json; print(json.load(open('$SKILL_DIR/config/user.json')).get('retry', {}).get('delaySeconds', 60))" 2>/dev/null)
    [[ -n "$CONFIG_RETRY_DELAY" ]] && RETRY_DELAY=$CONFIG_RETRY_DELAY
    CONFIG_AUTO_MERGE=$(python3 -c "import json; print(1 if json.load(open('$SKILL_DIR/config/user.json')).get('pr', {}).get('autoMerge', False) else 0)" 2>/dev/null)
    [[ -n "$CONFIG_AUTO_MERGE" ]] && AUTO_MERGE_DEFAULT=$CONFIG_AUTO_MERGE
    CFG_AUTO_CLEANUP_ON_CHECK=$(python3 -c "import json; cfg=json.load(open('$SKILL_DIR/config/user.json')); print((cfg.get('cleanup') or {}).get('autoCleanup', True))" 2>/dev/null || echo "True")
    CFG_AUTO_PRUNE_ON_CHECK=$(python3 -c "import json; cfg=json.load(open('$SKILL_DIR/config/user.json')); print((cfg.get('archive') or {}).get('autoPruneOnCleanup', True))" 2>/dev/null || echo "True")
    CFG_AUTO_PRUNE_QUEUE_ON_CHECK=$(python3 -c "import json; cfg=json.load(open('$SKILL_DIR/config/user.json')); print((cfg.get('queueArchive') or {}).get('autoPruneOnCheck', True))" 2>/dev/null || echo "True")
    [[ "$CFG_AUTO_CLEANUP_ON_CHECK" == "False" || "$CFG_AUTO_CLEANUP_ON_CHECK" == "false" ]] && AUTO_CLEANUP_ON_CHECK=false
    [[ "$CFG_AUTO_PRUNE_ON_CHECK" == "False" || "$CFG_AUTO_PRUNE_ON_CHECK" == "false" ]] && AUTO_PRUNE_ON_CHECK=false
    [[ "$CFG_AUTO_PRUNE_QUEUE_ON_CHECK" == "False" || "$CFG_AUTO_PRUNE_QUEUE_ON_CHECK" == "false" ]] && AUTO_PRUNE_QUEUE_ON_CHECK=false
fi

# 检查依赖
check_required_dependencies 2>/dev/null || {
    echo "Warning: Some dependencies are missing, but continuing..."
}

echo "Checking agents..."

if [[ ! -f "$TASKS_FILE" ]]; then
    echo "No tasks file found"
    exit 0
fi

# 检查每个运行中的代理
acquire_file_lock "$TASKS_LOCK_DIR" 120 || exit 1
TEMP_FILE=$(mktemp)
cp "$TASKS_FILE" "$TEMP_FILE"

python3 << PYEOF
import json
import subprocess
import os
import time
import shlex
import shutil

MAX_RETRIES = $MAX_RETRIES
RETRY_DELAY = $RETRY_DELAY
REPOS_BASE = '$REPOS_BASE_DIR'
AUTO_MERGE_DEFAULT = bool($AUTO_MERGE_DEFAULT)

with open('$TEMP_FILE', 'r', encoding='utf-8') as f:
    data = json.load(f)

needs_update = False
notifications = []
now_ms = int(time.time() * 1000)

def gh_available():
    return shutil.which('gh') is not None

def gh_auth_ok():
    if not gh_available():
        return False
    proc = subprocess.run(['gh', 'auth', 'status'], capture_output=True, text=True)
    output = (proc.stdout or '') + (proc.stderr or '')
    if 'token in default is invalid' in output.lower():
        return False
    if 'not logged into any github hosts' in output.lower():
        return False
    return proc.returncode == 0

GH_READY = gh_auth_ok()

def set_cleanup_eligibility(agent, now_ms):
    cleanup_mode = agent.get('cleanupMode', 'none')
    if cleanup_mode != 'session_ttl':
        return
    ttl = agent.get('cleanupAfterSeconds')
    try:
        ttl = int(ttl) if ttl is not None else 3600
    except Exception:
        ttl = 3600
    ttl = max(0, ttl)
    agent['cleanupEligibleAt'] = now_ms + (ttl * 1000)

def restart_agent(agent):
    session = agent.get('tmuxSession', '')
    worktree = agent.get('worktree', '')
    command_shell = agent.get('commandShell', '')
    log_file = agent.get('logFile', '')
    launch_script = agent.get('launchScript', '')

    if not session or not worktree or not command_shell:
        return False, 'missing session/worktree/command metadata'

    if not os.path.isabs(worktree):
        worktree = os.path.abspath(os.path.join(os.path.dirname('$TASKS_FILE'), worktree))

    if not os.path.exists(worktree):
        return False, f'worktree not found: {worktree}'

    if launch_script:
        if not os.path.isabs(launch_script):
            launch_script = os.path.abspath(os.path.join(os.path.dirname('$TASKS_FILE'), launch_script))
        if os.path.exists(launch_script):
            proc = subprocess.run(
                ['tmux', 'new-session', '-d', '-s', session, f"bash {shlex.quote(launch_script)}"],
                capture_output=True,
                text=True,
            )
            if proc.returncode == 0:
                return True, ''
            return False, (proc.stderr or proc.stdout or 'unknown tmux error').strip()

    if log_file:
        if not os.path.isabs(log_file):
            log_file = os.path.abspath(os.path.join(os.path.dirname('$TASKS_FILE'), log_file))
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        wrapped_cmd = f"cd {shlex.quote(worktree)} && {command_shell} 2>&1 | tee -a {shlex.quote(log_file)}"
    else:
        wrapped_cmd = f"cd {shlex.quote(worktree)} && {command_shell}"

    proc = subprocess.run(
        ['tmux', 'new-session', '-d', '-s', session, wrapped_cmd],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        return True, ''
    return False, (proc.stderr or proc.stdout or 'unknown tmux error').strip()

def get_log_observation(agent):
    log_file = agent.get('logFile', '')
    if not log_file:
        return {'exists': False, 'size': 0, 'mtime_ms': 0}
    if not os.path.isabs(log_file):
        log_file = os.path.abspath(os.path.join(os.path.dirname('$TASKS_FILE'), log_file))
    if not os.path.exists(log_file):
        return {'exists': False, 'size': 0, 'mtime_ms': 0}
    try:
        st = os.stat(log_file)
        return {'exists': True, 'size': int(st.st_size), 'mtime_ms': int(st.st_mtime * 1000)}
    except Exception:
        return {'exists': False, 'size': 0, 'mtime_ms': 0}

def detect_empty_shell_session(agent, now_ms):
    session = agent.get('tmuxSession', '')
    if not session:
        return False, ''
    checks = agent.setdefault('checks', {})

    pane = subprocess.run(
        ['tmux', 'list-panes', '-t', session, '-F', '#{pane_current_command}'],
        capture_output=True,
        text=True,
    )
    if pane.returncode != 0:
        return False, ''
    current_cmd = (pane.stdout or '').splitlines()[:1]
    current_cmd = (current_cmd[0].strip().lower() if current_cmd else '')
    shell_like = current_cmd in {'zsh', 'bash', 'sh', 'fish'}
    if not shell_like:
        checks['emptyShellStrikeCount'] = 0
        checks.pop('lastEmptyShellObservedAt', None)
        return False, ''

    obs = get_log_observation(agent)
    checks['lastObservedLogSize'] = obs['size']
    checks['lastObservedLogMtime'] = obs['mtime_ms']

    started_at = int(agent.get('startedAt') or 0)
    if started_at and (now_ms - started_at) < 15000:
        return False, ''

    strikes = int(checks.get('emptyShellStrikeCount') or 0)
    last_seen = int(checks.get('lastEmptyShellObservedAt') or 0)
    checks['lastEmptyShellObservedAt'] = now_ms

    if obs['size'] == 0:
        strikes += 1
        checks['emptyShellStrikeCount'] = strikes
        if strikes >= 2:
            return True, f'empty_shell_no_log(current={current_cmd})'
        return False, ''

    # 有日志内容但 pane 已退回 shell，给短缓冲，防止刚退出瞬间误判
    if last_seen and (now_ms - last_seen) < 10000:
        return False, ''
    strikes += 1
    checks['emptyShellStrikeCount'] = strikes
    if strikes >= 3:
        return True, f'empty_shell_after_output(current={current_cmd})'
    return False, ''

def handle_retry_or_fail(agent, now_ms, session, description, failure_reason):
    retry_count = int(agent.get('retryCount', 0) or 0)
    checks = agent.setdefault('checks', {})
    checks['lastFailureReason'] = failure_reason

    if retry_count >= MAX_RETRIES:
        set_status(agent, 'failed', now_ms, reason='retry_exhausted_without_pr')
        agent['failedAt'] = now_ms
        print(f"✗ Agent {session} failed after {retry_count} retries")
        maybe_notify(agent, 'error', f'❌ 任务失败: {description}')
        return

    last_retry_at = agent.get('lastRetriedAt', 0)
    if RETRY_DELAY > 0 and last_retry_at and (now_ms - last_retry_at) < RETRY_DELAY * 1000:
        remaining = int(RETRY_DELAY - ((now_ms - last_retry_at) / 1000))
        print(f"⏳ Agent {session} retry delayed ({max(0, remaining)}s left)")
        return

    next_retry = retry_count + 1
    ok, reason = restart_agent(agent)
    agent['retryCount'] = next_retry
    agent['lastRetriedAt'] = now_ms
    if ok:
        checks['emptyShellStrikeCount'] = 0
        checks.pop('lastEmptyShellObservedAt', None)
        print(f"↻ Agent {session} restarted ({next_retry}/{MAX_RETRIES})")
        maybe_notify(agent, 'warning', f'⚠️ 任务重试中 ({next_retry}/{MAX_RETRIES}): {description}')
        return

    print(f"⚠ Agent {session} restart failed ({next_retry}/{MAX_RETRIES}): {reason}")
    checks['lastRestartError'] = reason
    if next_retry >= MAX_RETRIES:
        set_status(agent, 'failed', now_ms, reason='restart_failed')
        agent['failedAt'] = now_ms
        maybe_notify(agent, 'error', f'❌ 任务失败(重启失败): {description}')

def task_repo_cwd(agent):
    repo = agent.get('repo', '')
    repo_path = agent.get('repoPath', os.path.join(REPOS_BASE, repo))
    return repo_path if repo_path and os.path.exists(repo_path) else None

def gh_cmd(args, agent=None):
    if not GH_READY:
        return None, 'gh_not_ready'
    cwd = task_repo_cwd(agent) if agent else None
    proc = subprocess.run(['gh'] + args, capture_output=True, text=True, cwd=cwd)
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout or 'gh command failed').strip()
    return proc.stdout, ''

def get_pr_info(agent):
    branch = agent.get('branch', '')
    checks = agent.setdefault('checks', {})
    pr_num = checks.get('prNumber')
    gh_repo = checks.get('ghRepo')

    if not pr_num:
        out, err = gh_cmd(['pr', 'list', '--head', branch, '--json', 'number,url,headRefName,baseRefName'], agent=agent)
        if out is None:
            checks['lastGhError'] = err
            return None, err
        try:
            arr = json.loads(out or '[]')
        except Exception:
            checks['lastGhError'] = 'invalid gh pr list json'
            return None, 'invalid gh pr list json'
        if not arr:
            return None, 'pr_not_found'
        item = arr[0]
        pr_num = item.get('number')
        checks['prNumber'] = pr_num
        checks['prUrl'] = item.get('url')
        if item.get('baseRefName'):
            checks['prBaseRef'] = item.get('baseRefName')
        needs = True
    else:
        needs = False

    view_fields = 'number,url,state,isDraft,reviewDecision,mergeStateStatus,mergedAt,updatedAt'
    out, err = gh_cmd(['pr', 'view', str(pr_num), '--json', view_fields], agent=agent)
    if out is None:
        checks['lastGhError'] = err
        return None, err
    try:
        pr = json.loads(out)
    except Exception:
        checks['lastGhError'] = 'invalid gh pr view json'
        return None, 'invalid gh pr view json'

    checks['prNumber'] = pr.get('number')
    checks['prUrl'] = pr.get('url')
    checks['prState'] = pr.get('state')
    checks['reviewDecision'] = pr.get('reviewDecision')
    checks['mergeStateStatus'] = pr.get('mergeStateStatus')
    checks['prMergedAt'] = pr.get('mergedAt')
    if needs:
        pass
    return pr, ''

def get_pr_checks(agent, pr_number):
    checks = agent.setdefault('checks', {})
    out, err = gh_cmd(['pr', 'checks', str(pr_number), '--required', '--json', 'bucket,name,state,workflow,link'], agent=agent)
    if out is None:
        if 'no required checks reported' in (err or '').lower():
            checks['requiredChecksSummary'] = {'bucket': 'none', 'total': 0}
            checks.pop('lastChecksError', None)
            return {'bucket': 'none', 'rows': []}, ''
        checks['lastChecksError'] = err
        return None, err
    try:
        rows = json.loads(out or '[]')
    except Exception:
        checks['lastChecksError'] = 'invalid gh pr checks json'
        return None, 'invalid gh pr checks json'

    if not rows:
        checks['requiredChecksSummary'] = {'bucket': 'none', 'total': 0}
        return {'bucket': 'none', 'rows': []}, ''

    buckets = [r.get('bucket') for r in rows]
    if any(b == 'fail' for b in buckets):
        bucket = 'fail'
    elif any(b in ('pending', 'cancel') for b in buckets):
        bucket = 'pending'
    elif all(b in ('pass', 'skipping') for b in buckets):
        bucket = 'pass'
    else:
        bucket = 'pending'
    checks['requiredChecksSummary'] = {'bucket': bucket, 'total': len(rows)}
    return {'bucket': bucket, 'rows': rows}, ''

def set_status(agent, new_status, now_ms, reason=None):
    global needs_update
    old_status = agent.get('status')
    if old_status != new_status:
        agent['status'] = new_status
        agent.setdefault('statusHistory', []).append({
            'from': old_status,
            'to': new_status,
            'at': now_ms,
            'reason': reason
        })
        needs_update = True
        return True
    return False

def maybe_notify(agent, ntype, message):
    notifications.append({
        'type': ntype,
        'message': message,
        'repo': agent.get('repo', ''),
        'branch': agent.get('branch', '')
    })

def try_merge_pr(agent, pr_number):
    checks = agent.setdefault('checks', {})
    merge_method = agent.get('mergeMethod') or 'squash'
    args = ['pr', 'merge', str(pr_number), f'--{merge_method}', '--delete-branch']
    # 非交互场景优先启用 auto merge（如果仓库支持）
    if agent.get('autoMerge') or AUTO_MERGE_DEFAULT:
        args.append('--auto')
    out, err = gh_cmd(args, agent=agent)
    if out is None:
        checks['lastMergeError'] = err
        return False, err
    checks['mergeTriggeredAt'] = now_ms
    checks['mergeCommand'] = ' '.join(args)
    return True, ''

def advance_pr_pipeline(agent):
    global needs_update
    description = agent.get('description', '')
    branch = agent.get('branch', '')
    checks = agent.setdefault('checks', {})

    pr, err = get_pr_info(agent)
    if pr is None:
        if err in ('gh_not_ready', 'pr_not_found'):
            return
        return

    pr_number = pr.get('number')
    pr_url = pr.get('url')
    review_decision = (pr.get('reviewDecision') or '').upper()
    merge_state_status = (pr.get('mergeStateStatus') or '').upper()
    merged_at = pr.get('mergedAt')
    pr_state = (pr.get('state') or '').upper()
    is_draft = bool(pr.get('isDraft'))
    checks_result, _ = get_pr_checks(agent, pr_number)
    checks_bucket = (checks_result or {}).get('bucket', 'pending')

    if merged_at or pr_state == 'MERGED':
        changed = set_status(agent, 'merged', now_ms, reason='pr_merged')
        agent['completedAt'] = now_ms
        checks['prMerged'] = True
        checks['prMergedAt'] = merged_at or checks.get('prMergedAt')
        if changed:
            print(f"✓ PR merged for {branch} (#{pr_number})")
            maybe_notify(agent, 'success', f'✅ PR 已合并: {description}')
        return

    checks['prUrl'] = pr_url
    checks['prNumber'] = pr_number
    checks['isDraft'] = is_draft
    checks['reviewDecision'] = review_decision or None
    checks['mergeStateStatus'] = merge_state_status or None
    needs_update = True

    if is_draft:
        set_status(agent, 'waiting_pr_ready', now_ms, reason='draft_pr')
        return

    if checks_bucket == 'fail':
        changed = set_status(agent, 'checks_failed', now_ms, reason='required_checks_failed')
        if changed:
            print(f"✗ Required checks failed for {branch} (#{pr_number})")
            maybe_notify(agent, 'error', f'❌ CI 检查失败: {description}')
        return

    if checks_bucket == 'pending':
        set_status(agent, 'waiting_checks', now_ms, reason='required_checks_pending')
        return

    # checks pass/none -> evaluate human review + AI review aggregate
    if review_decision == 'CHANGES_REQUESTED':
        changed = set_status(agent, 'changes_requested', now_ms, reason='review_changes_requested')
        if changed:
            print(f"⚠ Changes requested for {branch} (#{pr_number})")
            maybe_notify(agent, 'warning', f'⚠️ 审查要求修改: {description}')
        return

    ai_review_done = bool(checks.get('codeReviewDone'))
    ai_review_agg = checks.get('reviewAggregate') or {}
    ai_task_status = ai_review_agg.get('taskStatus')
    ai_reason = ai_review_agg.get('reason')

    if ai_task_status in ('review_changes_requested', 'review_human_attention'):
        set_status(agent, ai_task_status, now_ms, reason=f'ai_review_aggregate:{ai_reason or "unknown"}')
        return

    if not ai_review_done:
        set_status(agent, 'waiting_review', now_ms, reason='checks_passed_waiting_ai_review')
        return

    if ai_task_status == 'waiting_human_approve':
        if review_decision != 'APPROVED':
            set_status(agent, 'waiting_human_approve', now_ms, reason='ai_review_pass_waiting_human_approve')
            return

    if review_decision == 'APPROVED' and merge_state_status in ('CLEAN', 'HAS_HOOKS', 'UNSTABLE', 'UNKNOWN'):
        changed = set_status(agent, 'merge_ready', now_ms, reason='checks_passed_review_ok')
        if changed:
            print(f"✓ PR merge-ready for {branch} (#{pr_number})")
            maybe_notify(agent, 'success', f'✅ PR 可合并: {description}')

        if agent.get('autoMerge') or AUTO_MERGE_DEFAULT:
            ok, merge_err = try_merge_pr(agent, pr_number)
            if ok:
                if set_status(agent, 'merge_queued', now_ms, reason='gh_pr_merge_auto'):
                    print(f"↻ Auto-merge queued for {branch} (#{pr_number})")
                    maybe_notify(agent, 'success', f'✅ 已触发自动合并: {description}')
            else:
                checks['lastMergeError'] = merge_err
                print(f"⚠ Auto-merge failed for {branch}: {merge_err}")
        return

    # Human review still needed (AI review may have passed, but GitHub reviewDecision not approved yet)
    set_status(agent, 'waiting_human_approve', now_ms, reason='checks_passed_waiting_human_approve')

for agent in data.get('agents', []):
    session = agent.get('tmuxSession', '')
    repo = agent.get('repo', '')
    repo_path = agent.get('repoPath', os.path.join(REPOS_BASE, repo))
    branch = agent.get('branch', '')
    description = agent.get('description', '')
    retry_count = agent.get('retryCount', 0)
    completion_mode = agent.get('completionMode', 'pr')
    status = agent.get('status')

    if completion_mode == 'pr' and status in {'waiting_pr_ready', 'waiting_checks', 'checks_failed', 'waiting_review', 'review_commented', 'review_changes_requested', 'review_human_attention', 'waiting_human_approve', 'changes_requested', 'merge_ready', 'merge_queued'}:
        advance_pr_pipeline(agent)
        continue

    if status != 'running':
        continue

    # 检查 tmux 会话是否存在
    result = subprocess.run(['tmux', 'has-session', '-t', session], capture_output=True)
    forced_unhealthy_reason = None
    if result.returncode == 0:
        unhealthy, unhealthy_reason = detect_empty_shell_session(agent, now_ms)
        if unhealthy:
            forced_unhealthy_reason = unhealthy_reason or 'empty_shell'
            agent.setdefault('checks', {})['lastUnhealthySessionReason'] = forced_unhealthy_reason
            agent.setdefault('checks', {})['lastUnhealthyAt'] = now_ms
            print(f"⚠ Session {session} unhealthy ({forced_unhealthy_reason}), killing for retry")
            subprocess.run(['tmux', 'kill-session', '-t', session], capture_output=True)
            result = subprocess.CompletedProcess(args=['tmux', 'has-session', '-t', session], returncode=1)
            needs_update = True

    if result.returncode != 0:
        # 会话已终止 - 检查 PR 是否已创建
        print(f"Session {session} died")

        if completion_mode == 'session' and not forced_unhealthy_reason:
            agent['status'] = 'done'
            agent['completedAt'] = int(time.time() * 1000)
            agent.setdefault('checks', {})['completedBy'] = 'session_exit'
            set_cleanup_eligibility(agent, now_ms)
            print(f"✓ Agent {session} completed - session exit mode")
            notifications.append({
                'type': 'success',
                'message': f'✅ 任务完成(本地会话模式): {description}',
                'repo': repo,
                'branch': branch
            })
            needs_update = True
            continue

        if completion_mode == 'session' and forced_unhealthy_reason:
            handle_retry_or_fail(agent, now_ms, session, description, forced_unhealthy_reason)
            needs_update = True
            continue

        # 检查 PR
        pr_check = None
        if GH_READY and os.path.exists(repo_path):
            pr_check = subprocess.run(['gh', 'pr', 'list', '--head', branch],
                                     capture_output=True, text=True, cwd=repo_path)
        elif GH_READY:
            # 尝试从远程检查
            pr_check = subprocess.run(['gh', 'pr', 'list', '--head', branch],
                                     capture_output=True, text=True)

        if pr_check and pr_check.stdout.strip():
            set_status(agent, 'waiting_checks', now_ms, reason='pr_created')
            agent.setdefault('checks', {})['prCreated'] = True
            print(f"✓ Agent {session} completed - PR created, waiting checks")
            maybe_notify(agent, 'success', f'✅ PR 已创建，等待 CI: {description}')
            needs_update = True
            advance_pr_pipeline(agent)
        else:
            failure_reason = forced_unhealthy_reason or 'session_exit_without_pr'
            handle_retry_or_fail(agent, now_ms, session, description, failure_reason)
            needs_update = True

if not GH_READY:
    print("GH not ready (not logged in or token invalid); PR/CI/review pipeline checks skipped")

if needs_update:
    with open('$TEMP_FILE', 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print("Updated task registry")

# 更新活跃计数
data['activeCount'] = len([a for a in data.get('agents', []) if a.get('status') == 'running'])
with open('$TEMP_FILE', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f"Active agents: {data['activeCount']}")

# 写入通知文件
if notifications:
    with open('$NOTIFY_FILE', 'w', encoding='utf-8') as f:
        json.dump(notifications, f, indent=2, ensure_ascii=False)
    print(f"Written {len(notifications)} notifications")
PYEOF

# 检查 Python 脚本是否成功
if [[ $? -eq 0 ]]; then
    mv "$TEMP_FILE" "$TASKS_FILE"
else
    rm -f "$TEMP_FILE"
    exit 1
fi

# 释放 active-tasks 锁后再触发后续维护脚本，避免自锁
release_file_lock "$TASKS_LOCK_DIR"

if [[ "$AUTO_CLEANUP_ON_CHECK" == "true" && -x "$SKILL_DIR/scripts/cleanup-worktrees.sh" ]]; then
    echo "Auto cleanup after check-agents..."
    "$SKILL_DIR/scripts/cleanup-worktrees.sh" || echo "Warning: cleanup-worktrees.sh failed"
elif [[ "$AUTO_PRUNE_ON_CHECK" == "true" && -x "$SKILL_DIR/scripts/prune-history.sh" ]]; then
    echo "Auto prune after check-agents..."
    "$SKILL_DIR/scripts/prune-history.sh" || echo "Warning: prune-history.sh failed"
fi

if [[ -x "$SKILL_DIR/scripts/sync-queue-status.sh" ]]; then
    echo "Sync queue status after check-agents..."
    "$SKILL_DIR/scripts/sync-queue-status.sh" || echo "Warning: sync-queue-status.sh failed"
fi

if [[ "$AUTO_PRUNE_QUEUE_ON_CHECK" == "true" && -x "$SKILL_DIR/scripts/prune-queue-history.sh" ]]; then
    echo "Prune queue history after check-agents..."
    "$SKILL_DIR/scripts/prune-queue-history.sh" || echo "Warning: prune-queue-history.sh failed"
fi
