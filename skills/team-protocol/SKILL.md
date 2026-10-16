---
name: team-protocol
description: How to play your part in a team of avatars -- doer, reviewer or parent -- over typed mail. Use it when `mailbox team` shows you a team, when a "[mailbox]" line names typed mail (task, review, objection, agree, done, dispute, decision, stuck), and after a reset. The mailbox skill has the commands; this one is the judgment the watcher cannot check.
version: 0.1.1
author: avatar-builder
---

# team-protocol — working in a team

Your team view (`mailbox team`) says who your parent is, who your children are
and who your review partners are. The mailbox enforces what a machine can see:
who may send which type to whom, that a `reset` comes only after your
`checkpoint`, that a `done` follows an `agree` on the same task. Do not re-check
those. What it cannot see is whether a task is clear, a review real, or a dispute
fair. That part is yours, and it is what this skill is about.

Typed mail moves work from one state to the next. Use untyped mail for anything
else, such as a question or a pointer. In a team, a typed reply that the protocol
calls for is not ceremony: your partner or parent is waiting on it.

**`status` is a question, not a report.** The recipient's watcher answers it
with its own context numbers, and its session never sees the mail. To report
where you are, send untyped mail, or the type the protocol calls for.

## Task ids

The parent mints a task id when it sends the `task`: short and unique within the
team, such as `T-12`. Every message about that work carries the same id
(`--task T-12`), in both directions and across resets. A follow-up piece of work
is a new task with a new id, not a reuse of the old one.

## As a doer

- **A `task` is your instruction.** It names the doer, the reviewer and *done
  when*. If *done when* is missing or cannot be checked, ask the parent in
  untyped mail before starting. Do not guess at the finish line.
- **Work in chunks.** At a clean boundary, checkpoint the way your session cycle
  says. The checkpoint mail to your parent is sent for you.
- **Commit memory as `memory/<file>`.** If your harness reaches the memory
  directory through a symlink (Claude's `.claude/projects/…/memory` does), git
  refuses that path: `beyond a symbolic link`.
- **After a reset, send `ready`** with one line: what you are about to do. The
  reset may name which task to pick up. New work only ever arrives as its own
  `task`.
- **When *done when* holds, send `review`** to the reviewer the task names. Say:
  - what changed, and where it is (commit, branch, MR, path);
  - how you verified it, by command and result;
  - what you are unsure of.

  Never certify your own work. That is the reviewer's job.
- **On an `objection`, answer every point.** Either fix it or show why it does
  not hold, then send `review` again. Each `review` → `objection` exchange is one
  round.
- **At `objection_rounds`** (from `mailbox team`) **without agreement, send
  `dispute`** to the parent. State both positions as their holders would, with the
  evidence on each side, so the parent can decide from the mail alone.
- **On an `agree`, send `done`** to the parent:
  - the result and where it is;
  - what the reviewer checked;
  - anything left open.

## As a reviewer

- **Be friendly and adversarial.** Try to break the work. Judge it against the
  task's *done when*, not against how you would have done it.
- **An `agree` names what you checked**: the commands you ran or the lines you
  read, and the results. It also names what you did *not* check. "Looks good"
  is not an agree, and the parent will treat it as no review.
- **An `objection` is specific**: the claim, your evidence, and what would
  satisfy you. Keep it to what blocks *done when*. Put lesser points as notes
  in your `agree`; they are not reasons to withhold it.
- **Do not object to win, and do not agree to finish.** If you cannot verify
  something, say so in the `agree` rather than holding the work hostage to it.
- **Answer promptly.** The doer has stopped and is waiting on you.

## As a parent

- **Write a `task` the doer can finish without you.** Give it:
  - the goal;
  - *done when*, as something checkable;
  - the doer and the reviewer;
  - the task id.

  Send it to the doer only; the reviewer is named, not copied.
- **Answer a `checkpoint` with `reset`.** Skim the handoff it carries first. If
  you want a different task picked up next, name its id in the body. Do not sit
  on a checkpoint: after `silent_parent_minutes` the child resets without you.
- **On a `dispute`, decide.** Send `decision` to both parties, with the reason
  and the evidence it rests on. If it is beyond you, escalate. You escalate to
  your own parent, or to the operator if you are the team's top.
- **On a `done`, check the agree is substantive** before accepting the work. A
  thin agree means another review round, not acceptance.
- **On `stuck`, unblock or escalate.** A child stuck on `context` may get a
  `limits` raise within the team's ceiling. Raise it only if the work truly
  cannot be cut smaller.

## When to stop and escalate

Escalate a repeated dispute on the same task, a child that keeps hitting its
limits, or work that turns out to need a decision nobody in the team holds.
Escalate it up, with the history in the mail. Do not loop on it.
