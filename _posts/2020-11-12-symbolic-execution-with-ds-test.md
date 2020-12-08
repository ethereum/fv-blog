---
layout: post
published: true
title: Symbolic Execution With `ds-test`
date: '2020-11-12'
author: David Terry
category: 'Research & Development'
---

The [latest release](https://github.com/dapphub/dapptools/releases/tag/hevm%2F0.43.0) of
[`hevm`](https://github.com/dapphub/dapptools/tree/master/src/hevm) incorporates the recently
introduced symbolic execution features into its unit testing framework.

This lets users of the [`dapp`](https://github.com/dapphub/dapptools/tree/master/src/dapp) smart
contract development framework prove properties about their contracts using the same syntax and
language features that they use to write the contracts themselves.

In this tutorial we will show how to use these new features to prove properties of your smart
contracts.

---

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [Installation](#installation)
- [Example Code](#example-code)
- [What Is Symbolic Execution?](#what-is-symbolic-execution)
- [Using `ds-test`](#using-ds-test)
- [Finding Counterexamples](#finding-counterexamples)
- [Execution Environment And Limits to Proof](#execution-environment-and-limits-to-proof)
- [Execution Against Mainnet State](#execution-against-mainnet-state)
- [Interactive Exploration](#interactive-exploration)
- [Limitations, Assumptions & Future Work](#limitations-assumptions--future-work)

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

## What Is Symbolic Execution?

Symbolic execution is a program analysis technique that keeps some of the program state in an
abstract form, meaning that instead of being set to a specific value, these portions of the state
are represented as a name with some constraints attached.

To make this more specific, consider the contract below:

```solidity
contract Add {
    function add(uint x, uint y) external pure returns (uint z) {
        require((z = x + y) >= x, "overflow!");
    }
}
```

If we were to execute the `add` method symbolically we could represent the calldata as two symbolic
variables (`x` and `y`) that are constrained so their value can only fit in the range of a
`uint256`. As we proceed through the program, we will encounter various potential branching points,
for example a `JUMPI` instruction. If both sides of the branching point are reachable (determined by
checking if the conjunction of all existing constraints and the jump condition is satisfiable), then
execution will split in two, and each branch will be explored seperately, with the jump condition
(or it's negation depending on which branch is being explored) being added as a constraint for that
particular branch.

This results in a tree of possible executions, for example for the `add` method, the execution tree
looks like this:

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
- `10`: `msg.value == 0 && x + y < x`: revert (overflow)
- `11`: `msg.value == 0 && x + y >= x`: return `x + y`

If we assert a property at every leaf in the execution tree, then we can be sure that that property
will hold for all possible values of each piece of symbolic state, allowing us to prove properties
that hold for *all possible inputs* to a given function.

## Using `ds-test`

[`ds-test`](https://github.com/dapphub/ds-test/blob/master/src/test.sol) is a solidity unit testing
libary with tight integration into `hevm`. `hevm` will execute as a test any method that meets the
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
| symbolic       | `prove` | optional  | exhaustive exploration of all possible exeuction paths      |

To illustrate the differences between the test types, consider the following example:

```solidity
pragma solidity ^0.6.12;
import {DSTest} from "ds-test/test.sol";

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
- `test_associativity_fuzz` will be executed many times (100 by default), with randomly generated values for `x`, `y`, and `z`.
- `prove_associativity` will be symbolically executed, with `x`, `y`, and `z` represented as symbolic variables.

Finally, it is possible to manipulate the execution environment (e.g. timestamp) from within
`ds-test` using by using hevm "[cheat codes](https://github.com/dapphub/dapptools/tree/master/src/hevm#cheat-codes)"

## Finding Counterexamples

Lets look at a more complex example, consider the following token contract:

```solidity
pragma solidity ^0.6.12;

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
contract TestToken is DSTest, SafeMath {
    function prove_transfer(address dst, uint amt) public {
        Token token = new Token(uint(-1));

        uint preBalThis = token.balanceOf(address(this));
        uint preBalDst  = token.balanceOf(dst);

        token.transfer(dst, amt);

        // balance of this has been reduced by `amt`
        assertEq(sub(preBalThis, token.balanceOf(address(this))), amt);

        // balance of dst has been increased by `amt`
        assertEq(sub(token.balanceOf(dst), preBalDst), amt);
    }
}
```

Interestingly, this test fails with the following output:

```
Running 1 tests for src/Solidity.t.sol:TestERC20
[FAIL] prove_transfer(address,uint256)

Failure: prove_transfer(address,uint256)

  Counter Example:

    result:   Return: 32 symbolic bytes
    calldata: prove_transfer(0x3bE95e4159a131E56A84657c4ad4D43eC7Cd865d, 76659960446604539291960111962233748565076778433776366035354251883061838872576)

    src/Solidity.t.sol:TestToken
     ├╴constructor
     ├╴setUp()
     │  └╴create ERC20@0xDB356e865AAaFa1e37764121EA9e801Af13eEb83 (src/Solidity.t.sol:89)
     │     ├╴Transfer(115792089237316195423570985008687907853269984665640564039457584007913129639935) (src/Solidity.t.sol:54)
     │     └╴← 2672 bytes of code
     └╴prove_transfer(address,uint256)
        ├╴log_named_address(«this», 0x3be95e4159a131e56a84657c4ad4d43ec7cd865d) (src/Solidity.t.sol:93)
        ├╴call ERC20::balanceOf(address)(0x3be95e4159a131e56a84657c4ad4d43ec7cd865d) (src/Solidity.t.sol:95)
        │  └╴← (uint256)
        ├╴call ERC20::balanceOf(address)(address) (src/Solidity.t.sol:96)
        │  └╴← (uint256)
        ├╴call ERC20::transfer(address,uint256)(address, uint256) (src/Solidity.t.sol:98)
        │  ├╴Transfer(uint256) (src/Solidity.t.sol:67)
        │  └╴← (bool)
        ├╴call ERC20::balanceOf(address)(address) (src/Solidity.t.sol:101)
        │  └╴← (uint256)
        ├╴log_bytes32(bytes32) (lib/ds-test/src/test.sol:108)
        ├╴log_named_uint(bytes32, uint256) (lib/ds-test/src/test.sol:109)
        ├╴log_named_uint(bytes32, uint256) (lib/ds-test/src/test.sol:110)
        ├╴call ERC20::balanceOf(address)(address) (src/Solidity.t.sol:104)
        │  └╴← (uint256)
        ├╴log_bytes32(bytes32) (lib/ds-test/src/test.sol:108)
        ├╴log_named_uint(bytes32, uint256) (lib/ds-test/src/test.sol:109)
        └╴log_named_uint(bytes32, uint256) (lib/ds-test/src/test.sol:110)
```

Looking into the output, we can see that this represents the case where `dst` is the same as the
sender (in this case the test contract).

In this case the counter example found doesn't represent a bug in the implementation of `transfer`,
but rather shows that our understanding of the expected behaviour was flawed: an exhaustive
description of the behaviour of `transfer` must take self transfers into account. This kind of
situation is common when applying formal methods, where we are forced to consider all possible edge
cases.

It is also worth noting that fuzzing would be very unlikely to catch this edge case: there are 2^20
possible addresses, and the chance that a randomly generated address would match the address of the
test contract is miniscule. You can try it out yourself by renaming the `prove_transfer` method to
`test_transfer` and seeing if a counter example is found.

A test for `transfer` that takes self-transfers into account could look like this:

```solidity
function prove_transfer(address dst, uint amt) public {
    log_named_address("this", address(this));

    uint preBalThis = token.balanceOf(address(this));
    uint preBalDst  = token.balanceOf(dst);

    token.transfer(dst, amt);

    // no change for self-transfer
    uint delta = dst == address(this) ? 0 : amt;

    // balance of this has been reduced by `delta`
    assertEq(sub(preBalThis, token.balanceOf(address(this))), delta);

    // balance of dst has been increased by `delta`
    assertEq(sub(token.balanceOf(dst), preBalDst), delta);
}
```

## Execution Environment And Limits to Proof

In order to understand the limits of the proofs that it is possible to produce using this framework,
an understanding of the environment in which they are run is essential:

- All variables in the environment (e.g. caller, gas, timestamp) remain concrete
- All storage slots are set to zero at the beginning of the tests (meanings tests are effectively run against an empty blockchain)

In fact, the only symbolic variables introduced into the test environment are those that are
specified in the signature of the test method. This means that the proofs are exhaustive *only over
the input variables*. As an example, consider the `prove_transfer` test from the example above. The
`totalSupply` is always `uint(-1)`, and the test would not catch obviously faulty implementations of
`transfer` like the one below:

```solidity
function transfer(address dst, uint amt) public {
    require(totalSupply > uint56(-1), "whoops");
    balanceOf[msg.sender] = sub(balanceOf[msg.sender], amt);
    balanceOf[dst]        = add(balanceOf[dst], amt);
}
```

## Execution Against Mainnet State

`hevm` allows us to fetch state from an rpc node, and we can also use this to write symbolic tests
against mainnet state. As an example, lets run `prove_transfer` against the [balancer
token](https://etherscan.io/address/0xba100000625a3754423978a60c9317c58a424e3D#code):

```solidity
interface ERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract TestBal is DSTest, SafeMath {
    function prove_transfer(address dst, uint amt) public {
        // BAL: https://etherscan.io/address/0xba100000625a3754423978a60c9317c58a424e3D#code
        ERC20 token = ERC20(0xba100000625a3754423978a60c9317c58a424e3D);

        // ignore cases where we don't have engough tokens
        if (amt > bal.balanceOf(address(this))) return;

        uint preBalThis = token.balanceOf(address(this));
        uint preBalDst  = token.balanceOf(dst);

        token.transfer(dst, amt);

        // no change for self-transfer
        uint delta = dst == address(this) ? 0 : amt;

        // balance of `this` has been reduced by `delta`
        assertEq(sub(preBalThis, delta), bal.balanceOf(address(this)));

        // balance of `dst` has been increased by `delta`
        assertEq(add(preBalDst, delta), bal.balanceOf(dst);
    }
}
```

Lets run this test as the [balancer DAO](https://etherscan.io/token/0xba100000625a3754423978a60c9317c58a424e3d?a=0xb618f903ad1d00d6f7b92f5b0954dcdc056fc533) to make sure that we have plenty of `BAL`:

```
$ DAPP_TEST_ADDRESS=0xb618f903ad1d00d6f7b92f5b0954dcdc056fc533 dapp test --rpc-url <URL>
[FAIL] prove_transfer(address,uint256)

Failure: prove_transfer(address,uint256)

  Counter Example:

    result:   Revert("ERC20: transfer to the zero address")
    calldata: prove_transfer(0x0000000000000000000000000000000000000000, 0)
```

We have uncovered another edge case! The balancer token disallows transfers to the zero address.

It is also worth noting that symbolic execution against rpc state can be significantly more
performant than fuzzing via rpc.

## Interactive Exploration

`hevm` also includes a visual debugger, and we can use this to interactively explore the execution
tree. You can enter the debugger by running `dapp debug` from the root of your `dapp project`. You
will see a list of test methods, and once you select one you will be dropped into an interactive
debugging session.

You can press `h` to bring up a help view, `n` to step forwards, and `p` to step back. If you press
`e` in symbolic test you will jump to the next branching point, once there you can press `0` to choose
the branch which does not jump, and `1` to choose the branch that does.

Note that the interactive debugger will also function when executing against mainnet state.

A small demonstation video can be found below:




## Limitations, Assumptions & Future Work

**Non Linearity (`safeMul`)**

The symbolic execution engine in `hevm` is backed by an [SMT
solver](https://en.wikipedia.org/wiki/Satisfiability_Modulo_Theories) (currently either `z3` or
`cvc4` are supported). Expressions involving non-linear arithmetic (multiplication or divison by
symbolic variables) are extremely challenging for SMT solvers, and it will often not be possible to
symbolically execute tests involving lots of non linear arithmetic.

Unfortunately, non linear arithmetic is quite common in real world contracts (e.g.
[`safeMul`](https://github.com/dapphub/ds-math/blob/master/src/math.sol#L25) can easily
involve both a multiplication and a division by a symbolic variable).

We hope to include optimizations in future releases of `hevm` that reduce the load on the solver
when executing contracts that make use of common non-linearities (`safeMul` included).

**Symbolic Representation of Dynamic Types**

`hevm` is currently unable to represent dynamic types (e.g. `bytes`, `string`) symbolically. Tests
that need symbolic representations of dynamic data will currently fail with an `Unsupported symbolic
abiencoding` error.

We intend to lift this restriction in a future release of `hevm`.

**Symbolic Constructor Arguments**

Contract bytecode is currently assumed by `hevm` to be completely concrete. As constructor arguments
are implemented on the evm level by appending data to the contract's `creationCode`, symbolic
execution of contract constructors where the arguments are set to symbolic values will currently
fail with an `UnexpectedSymbolicArg` error.

We intend to lift this restriction in a future release of `hevm`.

**State Explosion**

Symbolic execution explores all possible paths through a program. If the program is large, or
contains many branches, this can become computationly very intensive. This issue is known as "state
explosion". While the relative simplicity of most smart contracts limits the impact, you should be
aware that exploration of very large or complex contract systems may become very time consuming.

In these cases it be convenient to first write your tests as fuzz tests, and only begin symbolically
executing once you have a set of properties that you are happy with.

**Storage Collisions**

Solidity mapping and dynamically-sized array types use a Keccak-256 hash computation to find the
starting position of the value or the array data
([ref](https://docs.soliditylang.org/en/v0.7.5/internals/layout_in_storage.html#mappings-and-dynamic-arrays)).
This scheme introduces a miniscule chance of storage overflow due to a hash collision.

In order to simplify the analysis, and to avoid cluttering the output with issues that will almost
certainly never occur, `hevm` assumes that the output of `keccak256` is always greater than 100,
meaning that the starting position of an array, or an element in a mapping will never collide with
any of the first 100 storage slots.


