# Mutation Verification

Every gate green does not mean the new tests test anything. This is the step that finds out: for
each assertion the change adds, break the code that assertion is about and watch that assertion
fail.

It is a separate step from `/code-review` because it answers a different question, and neither
answer implies the other:

- **All gates green, review clean, and the new specs still vacuous.** Reviewing a test reads what
  it _says_; a test says the right thing and still passes for a reason unrelated to it.
- **Every mutation killed, and the change still wrong.** Mutation testing only ever asks about the
  code you thought to mutate. The two real defects found on the same run had both passed a full
  mutation pass — they lived on call sites nobody had listed (`vibing-orchestrate` → "Check
  coverage, not design").

So: mutation verification measures the tests, review and coverage measure the change. Run both.

## Evidence

Three vacuous tests from one 15-PR run, none of which any gate or review reported:

| What was wrong                                                      | How it surfaced                                                                                                                             |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| A spec that survived every mutation aimed at the behaviour it named | M1–M9 all passed. Only M10/M11 — which broke the code path itself rather than its outputs — killed it, and writing those is what exposed it |
| An assertion written as "at least one input field"                  | Passed under M15, which added a second one. Rewritten as "exactly one", it fails                                                            |
| A positive control a worker wrote for its own new guard             | Did not die under M2. The warning it asserted on was being emitted from a different branch than the one it was supposed to be covering      |

The third is the one to keep in mind: a control written specifically to prove a test is not
vacuous can itself be vacuous. Nothing is exempt from being run against a broken tree.

## How to run it

1. **Finish the change and get the gates green first.** A mutation run against a tree that is
   already failing tells you nothing.
2. **Copy the file you are about to mutate** to a scratch path, and restore from that copy rather
   than by editing it back by hand. Reverting a mutation by re-editing is how a tree ends up with
   a mutation still applied and a "passing" result that means nothing; the
   `approval-without-kill` work lost a whole measurement to exactly that.
3. **One mutation at a time**, each the smallest change that removes the behaviour one new
   assertion claims: revert the line, flip the condition, drop the call, return early, return
   `nil`. Mutate the **source**, never the spec.
4. **Run the suite and record which specs died**, by name.
5. **Restore, and repeat** for the next assertion.

## Reading the result

- **A mutation nothing catches** is the finding. Decide out loud which it is: an assertion that
  cannot fail (fix the assertion), or a behaviour no test claims (write one, or say why it does
  not need one). Do not record it as "acceptable" without saying which.
- **A mutation that kills one named spec** is the strongest signal, and it is worth aiming for.
  Two mutations killing one spec each, and different ones, is evidence that two halves of a change
  are separately pinned — which a single mutation killing both would not show.
- **A mutation that kills forty specs** measured the code's centrality, not your new assertion.
  Aim it closer.
- **An assertion that needs a contrived mutation to fail** is usually testing an accident of the
  implementation rather than the invariant. Rewrite it against the invariant.

Record the table in the PR body — mutation, what it changed, which spec died — the way #801 did.
It is what lets a reviewer check the reasoning rather than re-run it.
