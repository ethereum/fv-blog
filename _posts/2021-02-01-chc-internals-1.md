---
layout: post
published: true
title: SMTChecker's CHC engine internals - part 1
date: '2021-01-22'
author: Leo Alt
category: 'Research & Development'
---

## The Fundamentals

I wrote [previously](https://fv.ethereum.org/2021/01/18/smtchecker-and-synthesis-of-external-functions/)
about how the SMTChecker's CHC engine can be used to prove contract invariants,
give transaction traces to bugs, and synthesize external calls to unknown code.

This post is the first of a series explaining the internals of the CHC engine,
starting with the fundamentals.
The formal description of the technique was published in [[1]](#references)

## Horn Clauses for Program Verification

A [Horn clause](https://en.wikipedia.org/wiki/Horn_clause) is a logical clause
of the form $$\forall x \; P(x) \land q \land \ldots \land t \implies R(x)$$,
where $$P$$ and $$R$$ are predicates, and $$q$$ and $$t$$ are constraints. They
are commonly used as symbolic representations of programs [[2]](#references),
where a Horn solver is used to answer program verification queries encoded as
Horn clauses. For a theoretical explanation of how they relate, please see
[[1][2]](#references).  In practice, the control flow graph for a program
written in an imperative language, seen as a transition system, translates
quite well to rules written as constrained Horn clauses.

For instance, take the following Solidity code:
```
function loopInv(uint8 n) public pure {
	uint8 x = 0;
	while (x < n)
		x++;
	assert(x == n);
}
```

A transition system based on the control flow graph for this function is:
![transition_system](https://fv.ethereum.org/img/2021/02/transition_system.png)

If we represent a node by a predicate over its scope, and edges by constraints,
the transition system above becomes the system of Horn clauses below:

1. $$loopInvStart(nInit, xInit, nCur, xCur)$$
2. $$loopInvStart(nInit, xInit, nCur, xCur) \land xInit = 0 \land xCur = xInit \land nInit \ge 0 \land nInit < 256 \land nCur = nInit \implies loopHeader(nInit, xInit, nCur, xCur)$$
3. $$loopHeader(nInit, xInit, nCur, xCur) \land xCur < nCur \implies loopBody(nInit, xInit, nCur, xCur)$$
4. $$loopHeader(nInit, xInit, nCur, xCur) \land xCur \ge nCur \implies loopInvBlock1(nInit, xInit, nCur, xCur)$$
5. $$loopBody(nInit, xInit, nCur, xCur) \implies loopHeader(nInit, xInit, nCur, xCur + 1)$$
6. $$loopInvBlock1(nInit, xInit, nCur, xCur) \land x \neq n \implies \bot$$
7. $$loopInvBlock1(nInit, xInit, nCur, xCur) \land x = n \implies summaryLoopInv(nInit, xInit, nCur, xCur)$$

Every symbolic variable above is implicitly universally quantified.
Please take a minute to go through the transition system and the rules above to
check whether they match (they should).  You'll understand soon why we need
$$init$$ and $$cur$$ versions for each program variable.

Clause 1 is implicitly implied by $$\top$$, which makes it a *fact*. This means
this predicate can be used as an entry point, in the same way that the node it
represents is the initial node in the transition system.

Clause 2 adds constraints for the initial values of $$x$$ and $$n$$: $$x$$ is
initialized as 0, and although we don't have a concrete value for $$n$$, we know
its type range constraints.

Clauses 3 and 4 enter and exit the loop, respectively.
Clause 5 updates the current value of $$x$$ and loops back to the loop header.

Clauses 2-5 are *definition* clauses which describe the transition system.

Clause 6 is a *goal* clause. We negate the goal we want to prove and tell the system
that this should not be true. If we can prove this, it means that the property we're
trying to prove is true **for every possible case**.

Clause 7 is also a definition clause that ends the function encoding by creating its summary.

Symbolic variables $$nInit$$ and $$xInit$$ represent the values of the program
variables $$n$$ and $$x$$ at the beginning of the transaction, and are never
modified throughout the encoding of the program. This is useful when building
function summaries of the form $$summaryLoopInv(preState, postState)$$ which
means that executing function $$loopInv$$ on $$preState$$ leads to $$postState$$.
As we will see later, this is crucial to encode function calls.

Note that the predicates we used to represent the transition system nodes are
*uninterpreted*, that is, there are no semantics associated with them.  In
fact, that's precisely what we're going to ask the Horn solver in order to
solve our program verification problem!

**Is there an interpretation for each predicate that is consistent with the
definition rules, such that $$false$$ is not reachable from a fact?**

If the solver says $$SAT$$, there is such an interpretation and the solver
gives you an inductive invariant for each predicate that leads to the proof
that the property is correct.

If the solver says $$UNSAT$$, there is no such interpretation, the property is
false, and the solver should give you a path with concrete values from a fact
to $$false$$.

Note that the interpretation of $$SAT$$ and $$UNSAT$$ here is the opposite of
SMT queries results for program verification, where you would negate the
property and ask whether there is an interpretation of the *variables* that
lead to the property being violated. In that case, $$SAT$$ usually means that
there is a bug and $$UNSAT$$ means it's correct.

If you want to try it out yourself, here's the system of Horn clauses above
written in `smt2`: [gist](https://gist.github.com/leonardoalt/8bd4b07dd2230e7085c44216aab88761)

The SMTChecker's CHC engine uses the Horn solver [Spacer](https://spacer.bitbucket.io/)
via the theorem prover [z3](https://github.com/Z3Prover/z3).
Running `z3` on the `smt2` file above (gist), we see:

```sh
$ z3 loop_invariant.smt2
sat
(
  (define-fun loopHeader ((x!0 Int) (x!1 Int) (x!2 Int) (x!3 Int)) Bool
    (<= (+ x!3 (* (- 1) x!2)) 0))
  (define-fun loopInvBlock1 ((x!0 Int) (x!1 Int) (x!2 Int) (x!3 Int)) Bool
    (and (<= (+ x!3 (* (- 1) x!2)) 0) (>= x!3 x!2)))
  (define-fun summaryLoopInv ((x!0 Int) (x!1 Int) (x!2 Int) (x!3 Int)) Bool
    true)
  (define-fun loopBody ((x!0 Int) (x!1 Int) (x!2 Int) (x!3 Int)) Bool
    (and (<= (+ x!3 (* (- 1) x!2)) 0) (not (<= x!2 x!3))))
  (define-fun loopInvStart ((x!0 Int) (x!1 Int) (x!2 Int) (x!3 Int)) Bool
    true)
)
```

The answer is given in `smt2`, and might look more complicated than it is.
This basically gives semantics to the previously uninterpreted predicates
we created to represent the transition system nodes. Writing it in a simpler
"math-y" way we have that:

1. $$\forall \; nInit, xInit, nCur, xCur \; . loopHeader(nInit, xInit, nCur, xCur) = xCur \le nCur$$
2. $$\forall \; nInit, xInit, nCur, xCur \; . loopInvBlock1(nInit, xInit, nCur, xCur) = xCur \le nCur \land xCur \ge nCur$$
3. $$\forall \; nInit, xInit, nCur, xCur \; . summaryLoopInv(nInit, xInit, nCur, xCur) = \top$$
4. $$\forall \; nInit, xInit, nCur, xCur \; . loopBody(nInit, xInit, nCur, xCur) = xCur \le nCur \land nCur > xCur$$
5. $$\forall \; nInit, xInit, nCur, xCur \; . loopInvStart(nInit, xInit, nCur, xCur) = \top$$

Invariant 1 is the most important for this problem: the solver automatically
infers that $$x \le n$$ is an inductive invariant for the program loop, that is,
it is true whenever the condition is evaluated.

Invariant 2 refers to the code block after the loop, therefore the solver also
notices that the loop condition must be false: $$x \ge n$$, otherwise we would
still be inside the loop. Combined with the loop invariant, we have that $$x
\le n \land x \ge n$$ and therefore $$x = n$$, which is what we wanted to
prove.

## References

[1] [Matteo Marescotti, Rodrigo Otoni, Leonardo Alt, Patrick Eugster, Antti E. J. Hyvärinen, Natasha Sharygina: *Accurate Smart Contract Verification Through Direct Modelling*. ISoLA (3) 2020: 178-194](https://link.springer.com/chapter/10.1007%2F978-3-030-61467-6_12)

[2] [Nikolaj Bjørner, Arie Gurfinkel, Ken McMillan and Andrey Rybalchenko: *Horn Clause Solvers for Program Verification*](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/nbjorner-yurifest.pdf)
