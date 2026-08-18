# additional_docs

Victor's working notes from building with Claude Code, committed so Lorenzo and
his LLM can see what was planned, what was verified, and what shipped.

## `.genie/` wins

`.genie/` is the source of truth. Nothing in this folder re-opens a DESIGN
decision or amends a WISH — the WISH's own decision 1 says the 17-entry DESIGN
decision table is binding and not re-litigated. Where a document here appears to
contradict `.genie/`, `.genie/` is correct and the file here is stale.

What this folder *is* for:

- **Findings** — external facts verified live (RPC probes, contract reads) that
  confirm or correct an assumption the WISH records as unverified.
- **Group plans** — how a given execution group was approached before writing code.
- **Completion notes** — the WISH explicitly requires these for groups 1, 3 and 5
  ("record which branch was taken", "the two addresses plus the `agentId` are
  recorded in the completion note") but doesn't say where they live. They live here.

## Layout

Mirrors `.genie`'s slug convention.

```
additional_docs/
  README.md
  agent-mandate-vault-gate/
    findings-external-deps.md    live verification of the plan's external dependencies
    group-1-plan.md              approach taken for group 1
    group-1-completion.md        the WISH-required completion note
```

## Branching

```
dev
 └── wish/agent-mandate-vault-gate      integration branch (the one the WISH declares)
      ├── feat/g1-toolchain             group 1
      ├── feat/g2-router                group 2   ┐ wave 2, parallel
      ├── feat/g3-vault                 group 3   ┘
      ├── feat/g4-fork-suite            group 4   ┐ wave 3, parallel
      └── feat/g5-deploy-demo           group 5   ┘
```

Branch-per-group is not cosmetic. Groups 2 and 3 both add files to `src/`, and
their WISH validation blocks *require* isolation — `forge test` compiles the
whole project before any `--match-*` filter applies, so a half-written
`src/AllowlistedERC4626.sol` would fail group 2's gate for reasons outside its
scope. A branch per group gives that isolation without needing worktrees.
