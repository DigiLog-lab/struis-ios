"""After main moves, delete the work branches of closed agent Issues (cleanup.sweep_closed).

Runs on Linux in agent.yml on a push to main. Bringing PRs up to date and verifying them again is the merge
queue's job now (scripts/ci/merge_queue.py): only the PR at the head of the queue is verified, so a merge no
longer starts a verification of every open PR.
"""
import cleanup
from agentlib import GitHub


def main():
    cleanup.sweep_closed(GitHub())


if __name__ == '__main__':
    main()
