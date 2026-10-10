---
name: lean
description: Use when editing `.lean` files or working in a Lake project.
---

# Lean 4 + Mathlib best practices

Conventions for any Lean 4 project — from experience, not language rules; deviate when warranted, but say why. Check for a project-local `BEST-PRACTICES.md` first (common in formalization projects); it overrides everything below.

## Workflow

1. Mark each `sorry` with what it's waiting on.
2. Keep build output clean before claiming done: remove `#check`/`#eval` probes, fix every linter warning, treat `lake build` noise as failure.
3. Helper results are `lemma`; reserve `theorem` for the headline results a reader should find.

## Definitions

- de Bruijn indices for binding in core formalizations — named representations drag alpha-equivalence bookkeeping everywhere.
- Derive `DecidableEq` and `Repr` on inductive types — unlocks `native_decide` on concrete examples and `#eval` debugging.
- Make key predicates `Decidable` (`Value`, `ClosedAt`, etc.) — enables `decide` / `native_decide` in proofs and tests.
- `@[simp]` on impossible-case lemmas pays for itself. Candidates: value predicates on non-value constructors, evaluation steps on irreducible forms, shifting/unshifting by 0.
  ```lean
  @[simp] lemma Eval.not_var : ¬ (var k ⟶ t) := nofun
  ```

## Proof tactics

- `omega` closes almost every `Nat` / `Int` arithmetic side-goal — reach for it before manual arithmetic.
- `nofun` / `nomatch` for impossible cases, tighter than `intro h; cases h`: `nofun` for function goals like `¬Value (var k)`, `nomatch h` when `h` has no inhabitants.
- `native_decide` for concrete term-level equalities (given `DecidableEq`); universally-quantified `n` needs induction.
- `solve_by_elim [...]` + `induction ... <;> cases ... <;>` is the standard preservation/progress skeleton. If it stalls, add `first | assumption | solve_by_elim [...]` fallbacks.
- `cases_type` for one extra inversion inside a tactic pipeline.

## Relations

- `ReflTransGen.lift` for congruence and inclusion, over manual `induction` with `| refl => ... | tail _ step ih => ...`:
  ```lean
  lemma EvalStar.app_left (h : t₁ ⟶* t₁') : app t₁ t₂ ⟶* app t₁' t₂ :=
    h.lift (app · t₂) fun _ _ => .app1

  theorem EvalByNameStar.toEvalFullBetaStar (h : t ⟶ₙ* t') : t ⟶f* t' :=
    h.lift id fun _ _ => EvalByName.toEvalFullBeta
  ```
- `ReflTransGen.head` exists as a lemma for prepending a step, not a constructor. Pattern-match on `refl`/`tail` for `cases`/`induction`.

## Inversion lemmas

- Induction-on-derivation proofs don't need them — `cases` or `solve_by_elim` suffice.
- Proofs about known term forms (canonical forms, simulation, decidable typing) benefit from named inversion lemmas; keep their proofs trivial:
  ```lean
  lemma HasType.inv_abs (h : Γ ⊢ .abs T₁ t ⦂ T) :
      ∃ T₂, T = T₁ ⇒ T₂ ∧ (T₁ :: Γ) ⊢ t ⦂ T₂ := by
    cases h; exact ⟨_, rfl, ‹_›⟩
  ```
  Don't mark these `@[simp]` — existential forms aren't simp-compatible.

## Common pitfalls

- The `List.getElem?_*` lemma family: `List.getElem?_cons_succ` only fires when the index is syntactically `n + 1`; for `k - m`, prepare `have : k - m = (k - m - 1) + 1 := by omega`.
- Namespace + dot-notation gotcha: `def Term.foo` inside namespace `A.B` creates `A.B.Term.foo`, not `Original.Term.foo`. To extend an external type, use a standalone name or enter its namespace explicitly.
- `Fin` `OfNat` wraps modulo: `(0 : Fin (n+1))` is `⟨0 % (n+1), _⟩`, not `⟨0, _⟩`, so matching on `⟨0, _⟩` won't fire. Bridge with `Fin.ext` or `omega`.
- `0 + n` is not `rfl`-equal to `n`: `Nat.add` recurses on the second argument, so `0 + n` is stuck. Use `Nat.zero_add` or `omega`.
- Explicit args beat failed inference: if a generic theorem is parameterized by something Lean can't infer (e.g. a relation `R`), make it explicit rather than forcing callers to write `(R := Eval)` everywhere.
- `notation` slots default to precedence 0, not `:max`. An unannotated slot lets any Mathlib infix (e.g. `⊣`, `infixl:15`) get consumed inside it, surfacing as a confusing "expected 'X'; got 'Y'". Annotate every slot `:max` (blocks any infix; parenthesised exprs still parse as atoms):
  ```lean
  notation "⟦" a:max " ⊩ " b:max " ⊣ " c:max " ⟧" => ...
  ```
  Also: `@` in a literal is eaten by the preceding slot as the explicit-application prefix — use a different glyph (e.g. `⊟`, U+229F).

## Lean LSP MCP server

Use the Lean LSP (ask for it to be installed if unavailable). Prefer these tools over re-running `lake build`:

- `lean_goal` — proof state at a cursor position.
- `lean_diagnostic_messages` — errors/warnings for a file.
- `lean_hover_info`, `lean_declaration_file`, `lean_references` — navigate.
- `lean_multi_attempt` — try several tactics at one cursor to see which succeeds (great for tactic search).
- `lean_loogle`, `lean_leansearch`, `lean_state_search`, `lean_hammer_premise` — search Mathlib by type / name / state.

Read a diagnostics result by its flags, not by the item count. A file is clean only when `success` is true; `success: false` with an empty `items` list means elaboration was still running when the call returned, which the response says in `partial`, `timed_out`, and `still_elaborating_lines`. Poll again, or warm the file with `lake build` first — a slow file (long tactic blocks, many-case `cases`) can outlast the wait on every call. `lean_goal` reports the same state as `status: "still_elaborating"`.

## Shared Lake cache (this machine)

Work in the checkout you're given and switch branches normally; `lean-cache` keeps the shared read-only Mathlib overlay current on its own. `.lake/packages` with one symlink per shared package is correct — don't "repair" it to a whole-directory symlink.

If Lake can't find Mathlib, run `lean-cache use` from the repo root (idempotent; derives the toolchain from `lean-toolchain`). A cold `.lake/build` rebuilds from scratch and can time out the LSP — run `lake build` to warm it before relying on `#eval`/LSP.
