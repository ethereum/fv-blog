---
layout: post
published: true
title: Symbolic Execution With ds-test
date: '2020-12-10'
author: David Terry
category: 'Research & Development'
---

The [latest release](https://github.com/dapphub/dapptools/releases/tag/hevm%2F0.43.0) of
[`hevm`](https://github.com/dapphub/dapptools/tree/master/src/hevm) incorporates the recently
introduced symbolic execution features into its unit testing framework.

This lets smart contract developers formulate and prove properties in Solidity using the
[`dapp`](https://github.com/dapphub/dapptools/tree/master/src/dapp) development framework. Formally
verifying properties should now be no harder than writing a property based test. In fact, it uses
almost the exact same syntax!

As an example, the following is a proof of the [distributive
property](https://en.wikipedia.org/wiki/Distributive_property) for EVM addition and multiplication:

```solidity
function prove_distributivity(uint x, uint y, uint z) public {
    assertEq(
        x * (y + z),
        (x * y) + (x * z)
    );
}
```

In this tutorial we will show how to use these new features to prove properties of your smart
contracts.

---

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [Installation](#installation)
- [What Is Symbolic Execution?](#what-is-symbolic-execution)
- [Using `ds-test`](#using-ds-test)
- [Setting Up the Environment](#setting-up-the-environment)
- [Finding Counterexamples](#finding-counterexamples)
- [Narrowing The Range of Test Inputs](#narrowing-the-range-of-test-inputs)
- [Execution Environment And Limits to Proof](#execution-environment-and-limits-to-proof)
- [Execution Against Mainnet State](#execution-against-mainnet-state)
- [Interactive Exploration](#interactive-exploration)
- [Limitations, Assumptions & Future Work](#limitations-assumptions--future-work)
    - [Non-Linearity (`safeMul`)](#non-linearity-safemul)
    - [Loops](#loops)
    - [External Calls to Unknown Code](#external-calls-to-unknown-code)
    - [Symbolic Representation of Dynamic Types](#symbolic-representation-of-dynamic-types)
    - [Symbolic Constructor Arguments](#symbolic-constructor-arguments)
    - [State Explosion](#state-explosion)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Installation

If you want to follow along with the examples in this blog post, you need to install the
[`nix`](https://nixos.org/) package manager, and then install the
[`dapptools`](https://github.com/dapphub/dapptools) toolkit:

```sh
# user must be in sudoers
curl -L https://nixos.org/nix/install | sh

# Run this or login again to use Nix
. "$HOME/.nix-profile/etc/profile.d/nix.sh"

# install dapptools
curl https://dapp.tools/install | sh
```

You can start a new `dapp` project by running `dapp init` inside of an empty directory, this will
install `ds-test` as a submodule, and prepare the expected folder layout. A skeleton test file will
have been created at `src/<PROJECT_NAME>.t.sol`. You can run `dapp test` from the root of the
project to execute the unit tests, and `dapp help test` to get an overview of the available command
line options.

## What Is Symbolic Execution?

Symbolic execution is a program analysis technique that keeps some of the program state in an
abstract form, meaning that instead of being set to a specific value, these portions of the state
are represented by a variable with some constraints attached.

To make this more specific, consider the contract below:

```solidity
contract Add {
    function add(uint x, uint y) external pure returns (uint z) {
        require((z = x + y) >= x, "overflow!");
    }
}
```

When executing the `add` method symbolically, calldata is represented as two abstract words,`x` and
`y`, without further constraints. As we proceed through the program we will encounter potential
branching points, such as a `JUMPI` instruction. At this point, we check which branches are
reachable by checking if the conjunction of all existing constraints and the branching condition is
satisfiable. If both are reachable, then execution will split in two, and each branch will be
explored separately, with the branching condition being added as a constraint for that particular
branch.

This results in a tree of possible executions. For the `add` method, for example, the execution tree
looks like this (ignoring potential failures due to out of gas errors):

```
├ 0     msg.value > 0
│       Revert
│
└ 1     msg.value == 0
  │
  ├ 0   x + y < x
  │     Revert("overflow!")
  │
  └ 1   x + y >= x
        Return: x + y
```

Each leaf on the tree represents a possible execution path, and has some logical conditions
attached:

- `0`:  `msg.value > 0`: revert (`add` is not payable)
- `1-0`: `msg.value == 0 && x + y < x`: revert (overflow)
- `1-1`: `msg.value == 0 && x + y >= x`: return `x + y`

Since the execution tree is an exhaustive representation of potential execution paths, if we assert
a property at every leaf, then we can be sure that that property will hold for all possible values
of each piece of symbolic state, allowing us to prove properties that hold for *all possible inputs*
to a given function.

## Using `ds-test`

[`ds-test`](https://github.com/dapphub/ds-test/blob/master/src/test.sol) is the Solidity interface
to `hevm`'s unit testing functionality. `hevm` will execute as a test any method that meets the
following criteria:

1. The method is on a contract that inherits from `DSTest`
1. The method is `public` or `external`
1. The method name starts with `test` or `prove`

If a public method named `setUp()` is present it will be executed before each test is run.

Three types of test are recognised by `hevm`:

| type           | prefix  | arguments | semantics                                                   |
|----------------|---------|-----------|-------------------------------------------------------------|
| concrete       | `test`  | no        | single execution with concrete values                       |
| property based | `test`  | yes       | multiple executions with randomly generated concrete values |
| symbolic       | `prove` | optional  | exhaustive exploration of all possible execution paths      |

To illustrate the differences between the test types, consider the following example:

```solidity
contract Test is DSTest {
    function test_associativity() public {
        assertEq(
            uint((1 + 2) + 3),
            uint(1 + (2 + 3))
        );
    }

    function test_associativity_fuzz(uint x, uint y, uint z) public {
        assertEq(
            (x + y) + z,
            x + (y + z)
        );
    }

    function prove_associativity(uint x, uint y, uint z) public {
        assertEq(
          (x + y) + z,
          x + (y + z)
        );
    }
}
```

- `test_associativity` will run a single test case with the concrete values of `1`, `2`, and `3`.
- `test_associativity_fuzz` will be executed many times (100 by default), with randomly generated values for `x`, `y`, and `z` for each run.
- `prove_associativity` will be symbolically executed, with `x`, `y`, and `z` represented as symbolic variables.

Each one of these test types has an additional `fail` variant, which will pass when at least one of
the assertions within the test is violated. This is indicated by prefixing the test name with
`testFail` or `proveFail` (e.g. `testFail_associativity`). In the case of symbolic tests, there must
be an assertion violation in every leaf on the execution tree for the `proveFail` test to pass.

For an overview of the available assertions and logging events, the [source
code](https://github.com/dapphub/ds-test/blob/master/src/test.sol) is the best reference.

## Setting Up the Environment

There are a few ways in which the test environment can be prepared:

1. Constructing and configuring contracts in the `setUp` phase
1. Pulling state from an ethereum node via rpc ([more details](#execution-against-mainnet-state)).
1. Tweaking the environment (e.g. caller, timestamp, block number, or even arbitrary storage slots)
   from within `ds-test` by using hevm [cheat
   codes](https://github.com/dapphub/dapptools/tree/master/src/hevm#cheat-codes), or the
   `DAPP_TEST_*` [environment
   variables](https://github.com/dapphub/dapptools/tree/master/src/hevm#environment-variables).

Note that all of these methods can be combined in arbitrary ways, e.g. you can pull a contract's
state from mainnet, modify it's storage to make yourself the owner, jump forwards 100 blocks, and
then make a few calls into that contract, before running your test cases against the new state.

## Finding Counterexamples

Let's look at a more complex example! Consider the following token contract:

```solidity
contract SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, "overflow");
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, "underflow");
    }
}

contract Token is SafeMath {
    uint256 public totalSupply;
    mapping (address => uint) public balanceOf;

    constructor(uint _totalSupply) public {
        totalSupply           = _totalSupply;
        balanceOf[msg.sender] = _totalSupply;
    }

    function transfer(address dst, uint amt) public {
        balanceOf[msg.sender] = sub(balanceOf[msg.sender], amt);
        balanceOf[dst]        = add(balanceOf[dst], amt);
    }
}
```

We can write a test that asserts our expected behaviour for the transfer function as follows:

```solidity
contract TestToken is SafeMath, DSTest {
    Token token;
    function setUp() public {
        token = new Token(type(uint).max);
        log_named_address("this", address(this));
    }

    function prove_transfer(address dst, uint amt) public {
        uint preBalThis = token.balanceOf(address(this));
        uint preBalDst  = token.balanceOf(dst);

        token.transfer(dst, amt);

        // balance of `this` has been reduced by `amt`
        assertEq(token.balanceOf(address(this)), sub(preBalThis, amt));

        // balance of `dst` has been increased by `amt`
        assertEq(token.balanceOf(dst), add(preBalDst, amt));
    }
}
```

If we run this test with `dapp test -v`, it fails with the following output:

```
[FAIL] prove_transfer(address,uint256)

Failure: prove_transfer(address,uint256)

  Counterexample:

    result:   Revert("overflow")
    calldata: prove_transfer(0x3bE95e4159a131E56A84657c4ad4D43eC7Cd865d, 29439701909273478501181875661097080170793294512827181564594992945753195806720)

    src/Test.sol:TestToken
     ├╴constructor
     ├╴setUp()
     │  ├╴create Token@0xDB356e865AAaFa1e37764121EA9e801Af13eEb83 (src/Test.sol:69)
     │  │  └╴← 896 bytes of code
     │  └╴log_named_address("this", 0x3be95e4159a131e56a84657c4ad4d43ec7cd865d) (src/Test.sol:70)
     └╴prove_transfer(address,uint256)
        ├╴call Token::balanceOf(address)(0x3be95e4159a131e56a84657c4ad4d43ec7cd865d) (src/Test.sol:74)
        │  └╴← (uint256)
        ├╴call Token::balanceOf(address)(address) (src/Test.sol:75)
        │  └╴← (uint256)
        ├╴call Token::transfer(address,uint256)(address, uint256) (src/Test.sol:77)
        │  └╴← (0x)
        ├╴call Token::balanceOf(address)(address) (src/Test.sol:80)
        │  └╴← (uint256)
        ├╴log(string) (lib/ds-test/src/test.sol:124)
        ├╴log_named_uint(string, uint256) (lib/ds-test/src/test.sol:125)
        ├╴log_named_uint(string, uint256) (lib/ds-test/src/test.sol:126)
        └╴call Token::balanceOf(address)(address) (src/Test.sol:83)
           └╴← (uint256)
```

Looking into the output, we can see that this represents the case where `dst` is the same as the
sender (in this case the test contract).

In this case the counterexample found doesn't represent a bug in the implementation of `transfer`,
but rather shows that our understanding of the expected behaviour was flawed: an exhaustive
description of the behaviour of `transfer` must take self-transfers into account. This kind of
situation is common when applying formal methods, where we are forced to consider all possible edge
cases.

It is also worth noting that fuzzing would be very unlikely to catch this edge case: there are 2^20
possible addresses, and the chance that a randomly generated address would match the address of the
test contract is minuscule. You can try it out yourself by renaming the `prove_transfer` method to
`test_transfer` and seeing if a counterexample is found.

A test for `transfer` that takes self-transfers into account could look like this:

```solidity
function prove_transfer(address dst, uint amt) public {
    uint preBalThis = token.balanceOf(address(this));
    uint preBalDst  = token.balanceOf(dst);

    token.transfer(dst, amt);

    // no change for self-transfer
    uint delta = dst == address(this) ? 0 : amt;

    // balance of `this` has been reduced by `delta`
    assertEq(token.balanceOf(address(this)), sub(preBalThis, delta));

    // balance of `dst` has been increased by `delta`
    assertEq(token.balanceOf(dst), add(preBalDst, delta));
}
```

## Narrowing The Range of Test Inputs

It will often be the case that the system under test is expected to revert in some situations. In
these situations it can be desirable to limit the range of the test inputs so these cases are not
triggered.

As an example, consider a test for the `add` function from the introduction:

```solidity
library Add {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, "overflow!");
    }
}

contract TestAdd is DSTest {
    function prove_add(uint x, uint y) public {
        assertEq(Add.add(x, y), x + y);
    }
}
```

Running this test gives us the obvious counterexample:

```
[FAIL] prove_add(uint256,uint256)

Failure: prove_add(uint256,uint256)

  Counterexample:

    result:   Revert("overflow!")
    calldata: prove_add(1, 115792089237316195423570985008687907853269984665640564039457584007913129639935)
```

We can rewrite the test with an early return to skip the assertion violation in this branch of the
execution tree. If we wish to keep our specification exhaustive over the inputs, we can add a
`proveFail` test with an inverted condition that will always fail in the branches where overflow
does not occur:

```solidity
contract TestAdd is DSTest {
    function prove_add(uint x, uint y) public {
        if (x + y < x) return; // no overflow
        assertEq(Add.add(x, y), x + y);
    }
    function proveFail_add(uint x, uint y) public {
        require(x + y < x, "must overflow");
        assertEq(Add.add(x, y), x + y);
    }
}
```

## Execution Environment And Limits to Proof

In order to understand the limits of the proofs that can be produced with this framework, an
understanding of the environment in which they are run is essential:

- All variables in the environment (e.g. caller, gas, timestamp) remain concrete
- All storage slots are initialized with concrete values (by default to zero if RPC state is not used)

In fact, the only symbolic variables introduced into the test environment are those that are
specified in the signature of the test method. This means that the proofs are exhaustive *only over
the input variables*. As an example, consider the `prove_transfer` test from the example above. The
`totalSupply` is always `type(uint).max`, and the test would not catch obviously faulty implementations of
`transfer` like the one below:

```solidity
function transfer(address dst, uint amt) public {
    require(totalSupply == type(uint).max, "whoops");
    balanceOf[msg.sender] = sub(balanceOf[msg.sender], amt);
    balanceOf[dst]        = add(balanceOf[dst], amt);
}
```

## Execution Against Mainnet State

`hevm` allows us to fetch state from an RPC node, and we can also use this to write symbolic tests
against mainnet state. As an example, let's run `prove_transfer` against the [balancer
token](https://etherscan.io/address/0xba100000625a3754423978a60c9317c58a424e3D#code):

```solidity
interface ERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract TestBal is SafeMath, DSTest {
    function setUp() public {}

    function prove_transfer(address dst, uint amt) public {
        // BAL: https://etherscan.io/address/0xba100000625a3754423978a60c9317c58a424e3D#code
        ERC20 bal = ERC20(0xba100000625a3754423978a60c9317c58a424e3D);

        // ignore cases where we don't have enough tokens
        if (amt > bal.balanceOf(address(this))) return;

        uint preBalThis = bal.balanceOf(address(this));
        uint preBalDst  = bal.balanceOf(dst);

        bal.transfer(dst, amt);

        // no change for self-transfer
        uint delta = dst == address(this) ? 0 : amt;

        // balance of `this` has been reduced by `delta`
        assertEq(sub(preBalThis, delta), bal.balanceOf(address(this)));

        // balance of `dst` has been increased by `delta`
        assertEq(add(preBalDst, delta), bal.balanceOf(dst));
    }
}
```

Let's run this test as the [balancer
DAO](https://etherscan.io/token/0xba100000625a3754423978a60c9317c58a424e3d?a=0xb618f903ad1d00d6f7b92f5b0954dcdc056fc533)
to make sure that we have plenty of `BAL`:

```
$ DAPP_TEST_ADDRESS=0xb618f903ad1d00d6f7b92f5b0954dcdc056fc533 dapp test --rpc-url <URL>
[FAIL] prove_transfer(address,uint256)

Failure: prove_transfer(address,uint256)

  Counterexample:

    result:   Revert("ERC20: transfer to the zero address")
    calldata: prove_transfer(0x0000000000000000000000000000000000000000, 0)
```

We have uncovered another edge case! The balancer token disallows transfers to the zero address. If
you are interested in learning about more ERC20 edge cases, an extensive list is maintained at
[weird-er20](https://github.com/xwvvvvwx/weird-erc20).

## Interactive Exploration

`hevm` also includes a visual debugger, and we can use this to interactively explore the execution
tree. You can enter the debugger by running `dapp debug` from the root of your `dapp project`. You
will see a list of test methods, and once you select one you will be dropped into an interactive
debugging session.

You can press `h` to bring up a help view, `n` to step forwards, and `p` to step back. If you press
`e` in symbolic test you will jump to the next branching point. Once there you can press `0` to choose
the branch which does not jump, and `1` to choose the branch that does.

Note that the interactive debugger will also function when executing against mainnet state.

A small demonstration video can be found below:

[![asciicast](https://asciinema.org/a/z1gg559jjOFnmfwI8A5LxTM0T.svg)](https://asciinema.org/a/z1gg559jjOFnmfwI8A5LxTM0T)

## Limitations, Assumptions & Future Work

#### Non-Linearity (`safeMul`)

The symbolic execution engine in `hevm` is backed by an [SMT
solver](https://en.wikipedia.org/wiki/Satisfiability_Modulo_Theories) (currently either `z3` or
`cvc4` are supported). Expressions involving non-linear arithmetic (multiplication, division or
exponentiation by symbolic variables) are extremely challenging or impossible for SMT solvers, and
it will often not be practical to symbolically execute tests involving lots of non-linear
arithmetic.

Unfortunately, non-linear arithmetic is quite common in real world contracts (e.g.
[`safeMul`](https://github.com/dapphub/ds-math/blob/master/src/math.sol#L25) can easily
involve both a multiplication and a division by a symbolic variable).

We hope to include optimizations in future releases of `hevm` that reduce the load on the solver
when executing contracts that make use of common non-linearities (`safeMul` included).

#### Loops & Max Iterations

Loops can pose a significant challenge for symbolic execution. As an example consider the following
code:

```solidity
function prove_loop(uint n) public pure {
    uint counter;
    for (uint i = 0; i <= n; i++) {
        counter = i;
    }
    assertEq(counter, n);
}
```

Execution will branch each time it reaches the loop condition (one branch where `i == n`, and one
where the loop continues). This means that there are a total of 2^256 branches on the execution tree
for this method! This is simply impossible to execute on any existing hardware.

In cases like this, it may be helpful to restrict the maximum number of iterations that will be
executed for a given loop. This can be controlled via the `--max-iterations` flag, which places an
upper limit on the number of times any branching point may be revisited. This approach is known in
the literature as "Bounded Model Checking".

Strategies for exhaustive proofs involving dynamically bounded looping behaviour do exist, but are
not supported by `ds-test`. They are however available in other tools (for example in the chc engine
of solc's
[SMTChecker](https://docs.soliditylang.org/en/v0.7.5/security-considerations.html#formal-verification)).

#### External Calls to Unknown Code

`hevm` currently does not support symbolic execution of calls into unknown code. For example the
code below will fail with a `NotUnique` error (meaning that `hevm` is unable to determine a unique
target for the call):

```solidity
function prove_call(address target) public {
    target.call(hex'');
}
```

As above, proof strategies for calls to unknown code do exist, and are supported by the chc engine
of solc's
[SMTChecker](https://docs.soliditylang.org/en/v0.7.5/security-considerations.html#formal-verification).
The SMTChecker can even synthesize an example call target that would trigger an assertion violation
in the calling contract (for example via reentrancy).

#### Symbolic Representation of Dynamic Types

`hevm` is currently unable to represent dynamic types (e.g. `bytes`, `string`) symbolically. Tests
that need symbolic representations of dynamic data will currently fail with an `Unsupported symbolic
abiencoding` error.

We intend to lift this restriction in a future release of `hevm`.

#### Symbolic Constructor Arguments

Contract bytecode is currently assumed by `hevm` to be completely concrete. As constructor arguments
are implemented on the EVM level by appending data to the contract's `creationCode`, symbolic
execution of contract constructors where the arguments are set to symbolic values will currently
fail with an `UnexpectedSymbolicArg` error.

We intend to lift this restriction in a future release of `hevm`.

#### State Explosion

Symbolic execution explores all possible paths through a program. If the program is large, or
contains many branches, this can become computationally very intensive. This issue is known as "state
explosion". While the relative simplicity of most smart contracts limits the impact, you should be
aware that exploration of very large or complex contract systems may become very time consuming.

In these cases it may be convenient to first write your tests as fuzz tests, and only begin
symbolically executing once you have a set of properties that you are happy with.
