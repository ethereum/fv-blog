---
layout: post
published: true
title: FV Team Quarterly Update
date: '2021-04-02'
author: David Terry, Jack Ek, Leo Alt, Martin Lundfall
category: 'Research & Development'
---

This is a small update on the things we have been working on and
what we would like to achieve until the middle of the year.

Act
===

The current focus for [Act](https://github.com/ethereum/act) is the 0.1
release, and we are almost there.  This will be Act's first release including:

- Support to value types, pre and post conditions, contract invariants, storage updates.
- SMT backend to prove contract invariants and post conditions.
	* Inductive proofs or
	* Pretty printed counterexamples.
- `hevm` integration to prove that the bytecode is consistent with the storage updates.
- Many bug fixes.

After 0.1, we would like to extend the language to express loop invariants and
calls to untrusted code.

hevm
===

We have optimized `hevm` for working with safe arithmetic on the bytecode
level by using the techniques from [this paper](http://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/z3prefix.pdf).

Two new hevm cheat codes useful for fuzz testing functionality involving ecrecover
have been added; `sign` and `addr`. Cheat codes can now also be called with symbolic
arguments, making them available for use in formal verification.

Through further generalizations, `hevm` now admits symbolic constructor arguments
as well.

We have improved documentation to make `hevm` more accessible, and are now
working on a static binary for `hevm` which might ease some dependency issues
and improve usability. We also intend to add RPC support, support for symbolic dynamic types,
and synchronize loop invariants and calls to untrusted code with Act.


SMTChecker
==========

The SMTChecker has become more powerful and stable over the last months, but it
still lacked many usability features. We have recently added compiler options
that allow the user to fine tune the model checker, including choosing the
formal engine, verification targets and setting a timeout per query.
The `out of bounds` verification target was added, reporting invalid index
accesses.
Counterexamples improved a lot, now reporting internal and synthesized
reentrant calls, as well as concrete values for local variables.
We also wrote a [brand new tutorial for new users of the SMTChecker](https://docs.soliditylang.org/en/develop/smtchecker.html)!

We want to continue improving usability in the future, reporting contract and
loop invariants to the user, and creating a trusted mode for external calls to
aid testing.
