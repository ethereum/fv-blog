---
layout: post
published: true
title: SMTChecker, Remix & Dapptools
date: '2021-11-26'
author: Leo Alt
category: 'Research & Development'
---

The [SMTChecker](https://docs.soliditylang.org/en/v0.8.10/smtchecker.html)
is a formal verification module inside the Solidity compiler.
Historically it has been complicated to run the SMTChecker on your own contracts,
since you had to compile the compiler with an SMT/Horn solver, usually [z3](https://github.com/Z3Prover/z3).
We have been working on different solutions to this, and nowadays it is quite
easy to run it.

The Solidity compiler ships [binaries](https://github.com/ethereum/solidity/releases)
targeting 4 different systems, with different SMTChecker support:

- soljson.js, a WebAssembly binary that comes with z3.
- solc-macos, an OSX binary that comes with z3.
- solc-static-linux, a Linux binary that does not come with z3, but is able to dynamically
  load z3 at runtime if it is simply installed in the system.
- solc-windows.exe, a Windows binary that does not come with z3.

This means that if your development framework uses `soljson.js` or the OSX binary, or the Linux
binary and you have z3 installed, the SMTChecker should be available.

The old but still supported way to enable the tool is by using `pragma experimental SMTChecker;`
in your source code, be we are deprecating that in favor of the JSON field `settings.modelChecker`
and the `--model-checker-*` CLI options.
Solidity 0.9.0 will not accept the `pragma` anymore, only the JSON and CLI options.

### Remix

[Remix](https://remix.ethereum.org/) uses the WebAssembly binary, so the SMTChecker works out of the box.
It does not yet let you tweak the `settings.modelChecker` JSON field, but you can still
use the `pragma` version.

![remix_code](https://fv.ethereum.org/img/2021/11/remix_code.png)

The warning on line 15 comes from the SMTChecker:

![remix_cex](https://fv.ethereum.org/img/2021/11/remix_cex.png)

Note that the compilation time may increase considerably if you enable the SMTChecker,
since the SMT solver will run in the background,
trying to solve potentially several queries.

### Dapptools

[Dapptools](https://github.com/dapphub/dapptools/) has a tight integration with [hevm](https://fv.ethereum.org/2020/07/28/symbolic-hevm-release/)
and makes it quite easy to apply formal verification.
Dapptools uses `solc`'s system's binary via Nix, so if you use OSX you are
all set, and if you use Linux you just need to install the SMT solver z3.

This section is almost a transcript of the first part of my talk at [Formal Verification in the Ethereum Ecosystem](https://runtimeverification.com/events/formalverificationeth),
where I demoed SMTChecker + Dapptools.

The easiest way to run the SMTChecker here is by using `solc`'s [standard JSON interface](https://docs.soliditylang.org/en/v0.8.10/using-the-compiler.html#input-description).
You can generate a `solc` JSON input file of your Dapptools project with

```bash
$ dapp mk-standard-json &> smt.json
```

and then modify it manually to add the object

```json
"modelChecker": {
	"engine": "chc",
	"contracts": {
		"src/MyContract": [ "MyContract" ]
	},
	"targets": [ "assert" ]
}
```

Or use a one liner to do the same:

```bash
$ dapp mk-standard-json | jq '.settings += {"modelChecker": {"engine": "chc", "contracts": {"src/MyContract.sol": ["MyContract"]}, "targets": ["assert"]}}' &> smt.json
```

Since the SMTChecker runs at Solidity's compile time, now all you have to do is tell Dapptools to use that
input JSON file and re-compile:

```bash
$ DAPP_STANDARD_JSON=smt.json dapp build
```

The SMTChecker does not handle Dapptools' DSTest well, so it is recommended that you write a specific contract
with properties (assertions) you want to verify, and make that contract inherit from your main contract instead of calling it externally.
Then use this new contract as the target in the `settings.modelChecker.contracts` object above.

![dapptools_code](https://fv.ethereum.org/img/2021/11/dapptools_code.png)

New object in the input JSON file:

```json
"modelChecker": {
	"engine": "chc",
	"contracts": {
		"src/BinaryMachine.t.sol": [ "BinaryMachineProperties" ]
	},
	"targets": [ "assert" ]
}
```

By combining the properties contract, which can also be seen as specification, and DSTest, one can use both the
SMTChecker and hevm in the same setup.

SMTChecker analysis run:

![dapptools_smtchecker](https://fv.ethereum.org/img/2021/11/dapptools_smtchecker.png)

hevm fuzzer run:

![dapptools_hevm](https://fv.ethereum.org/img/2021/11/dapptools_hevm.png)

Note that `CHC` is the recommended engine, and you are advised to always set the single contract you
want to be verified, as this helps the solver a lot. It may also be useful to set which verification
targets you would like to be verified, as well as a custom timeout if the solver is failing at your
properties.

You can find all these options and their description in the [SMTChecker docs](https://docs.soliditylang.org/en/v0.8.10/smtchecker.html#smtchecker-options-and-tuning).

### Other frameworks

The tool is of course not limited to only these two frameworks, and you can
pretty much use the same technique above to enable the SMTChecker in
development frameworks that allow the user to run `solc` in the standard JSON
mode.

### Final Remarks

Hopefully we got to a point where at least running the SMTChecker is considered easy.
However, using it in a way that gives meaningful results can still be tricky.
It is important to be aware of the model checker options, to tell the tool which
specific contracts need to be verified, and to use the best engine.

It is also important to write properties about the contract. Those can be used as
specification, and can be verified (at least attempted) by multiple tools, as seen
in the Dapptools example above.

Lastly, the tools cannot do more than the underlying solvers they use.
In the Formal Verification industry it is essential to try as many engines, solvers,
and configurations as possible when dealing with complex problems and properties.
It is often the case that one different parameter can cause the solver to go the
right way and prove/disprove a property that other solvers and configurations
may timeout or run out of memory.
Currently the SMTChecker only uses one solver and one configuration by default,
which causes it to not be able to answer many properties.
It is possible, however, to use different solvers and any desired configuration.

In the next blog post I will show how to do that, and present some experiments
demonstrating how important it is to try different things when dealing with
hard properties.
