//===- LinalgOps.td - Linalg dialect ops -------------------*- tablegen -*-===//
//
// Part of the MLIR Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This is the operation definition file for linear algebra operations.
//
//===----------------------------------------------------------------------===//

#ifndef LINALG_OPS
#define LINALG_OPS

include "mlir/Dialect/AffineOps/AffineOpsBase.td"
include "mlir/Dialect/Linalg/IR/LinalgBase.td"

// Base class for Linalg dialect ops that do not correspond to library calls.
class Linalg_Op<string mnemonic, list<OpTrait> traits = []> :
    Op<Linalg_Dialect, mnemonic, traits> {
  // For every linalg op, there needs to be a:
  //   * void print(OpAsmPrinter &p, ${C++ class of Op} op)
  //   * LogicalResult verify(${C++ class of Op} op)
  //   * ParseResult parse${C++ class of Op}(OpAsmParser &parser,
  //                                         OperationState &result)
  // functions.
  let printer = [{ return ::print(p, *this); }];
  let verifier = [{ return ::verify(*this); }];
  let parser = [{ return ::parse$cppClass(parser, result); }];
}

def Linalg_RangeOp :
    Linalg_Op<"range", [NoSideEffect]>,
    Arguments<(ins Index:$min, Index:$max, Index:$step)>,
    Results<(outs Range)> {
  let summary = "Create a `range` type value, used to create `view`s";
  let description = [{
    The `linalg.range` op creates a `!linalg.range` from 3 values of type
    `index` that represent the min, max and step values of the `range`. This
    type does not pass function boundaries at the moment.

    Example:

    ```mlir
      %3 = linalg.range %0:%1:%2 : !linalg.range
    ````
  }];
  let builders = [OpBuilder<
    "Builder *builder, OperationState &result, Value min, Value max, "
    "Value step",
    [{
      auto rangeType = RangeType::get(builder->getContext());
      build(builder, result, rangeType, min, max, step);
    }]>];

  // Fully specified by traits.
  let verifier = ?;
}

def Linalg_SliceOp : Linalg_Op<"slice", [NoSideEffect]>,
    Arguments<(ins AnyStridedMemRef:$view, Variadic<AnyTypeOf<[Range, Index]>>:$indexings)>,
    Results<(outs AnyStridedMemRef)> {
  let summary = "Produce a rank-reduced `subview` of a base `view`.";
  let description = [{
    The `linalg.slice` op allows defining a subregion of a smaller rank than the
    operand `view` within the underlying buffer.

    A `linalg.slice` op takes a view and a variadic number of indexings and
    produces a `view` of the same elemental type. An indexing is either:
      1. a `linalg.range`, in which case it does not reduce the rank of the
         parent `view` along the corresponding dimension.
      2. an `index`, in which case it reduces the rank of the parent view by
         one.

    If an indexing extends past the size of the `view`, this is undefined
    behavior. Ideally the `linalg.slice` operation would automatically truncate
    it to be within bounds but there are tradeoffs involved now that `std.view`
    is a standard op.

    Examples:

      1. rank-preserving `slice`:

      ```mlir
        %4 = linalg.slice %0[%1, %2] : memref<?x?xf32, stride_spec>,
          !linalg.range, !linalg.range, memref<?x?xf32, stride_spec>
       ```

      2. rank-reducing `slice` (from 2-D to 1-D):

      ```mlir
        %4 = linalg.slice %0[%1, %2] : memref<?x?xf32, stride_spec>,
          index, !linalg.range, memref<?x?xf32, stride_spec>
      ```

      3. rank-reducing `slice` (from 2-D to 0-D):

      ```mlir
        %4 = linalg.slice %0[%1, %2] : memref<?x?xf32, stride_spec>,
          index, index, memref<?x?xf32, stride_spec>
      ```
  }];

  let builders = [OpBuilder<
    "Builder *b, OperationState &result, Value base, "
    "ValueRange indexings">];

  let extraClassDeclaration = [{
    enum { FirstIndexingOperand = 1 };
    unsigned getRank() { return getViewType().getRank(); }
    Type getElementType() { return getViewType().getElementType(); }
    MemRefType getViewType() { return getType().cast<MemRefType>(); }
    unsigned getBaseViewRank() { return getBaseViewType().getRank(); }
    MemRefType getBaseViewType() { return view()->getType().cast<MemRefType>(); }

    // Get the underlying indexing at a given rank.
    Value indexing(unsigned rank) { return *(indexings().begin() + rank); }

    // Get the subset of indexings that are of RangeType.
    SmallVector<Value, 8> getRanges() {
      SmallVector<Value, 8> res;
      for (auto operand : indexings())
        if (!operand->getType().isa<IndexType>())
          res.push_back(operand);
      return res;
    }
  }];
}

def Linalg_TransposeOp : Linalg_Op<"transpose", [NoSideEffect]>,
    Arguments<(ins AnyStridedMemRef:$view, AffineMapAttr:$permutation)>,
    Results<(outs AnyStridedMemRef)> {
  let summary = "transpose operation produces a new strided memref (metadata-only)";
  let description = [{
    The `linalg.transpose` op produces a strided memref whose sizes and strides
    are a permutation of the original `view`. This is a pure metadata
    transformation.

    Example:

    ```mlir
       %1 = linalg.transpose %0 (i, j) -> (j, i) : memref<?x?xf32, stride_spec>
    ```
  }];

  let builders = [OpBuilder<
    "Builder *b, OperationState &result, Value view, "
    "AffineMapAttr permutation, ArrayRef<NamedAttribute> attrs = {}">];

  let verifier = [{
    if (!permutation().isPermutation())
      return emitOpError("expected a permutation map");
    if (permutation().getNumDims() != getViewType().getRank())
      return emitOpError("expected a permutation map of same rank as the view");
    return success();
  }];

  let extraClassDeclaration = [{
    static StringRef getPermutationAttrName() { return "permutation"; }
    MemRefType getViewType() { return view()->getType().cast<MemRefType>(); }
  }];
}

def Linalg_YieldOp : Linalg_Op<"yield", [NativeOpTrait<"IsTerminator">]>,
    Arguments<(ins Variadic<AnyType>:$values)> {
  let summary = "Linalg yield operation";
  let description = [{
    `linalg.yield` is a special terminator operation for blocks inside regions
    in `linalg` generic ops. It returns values to the immediately enclosing
    `linalg` generic op.

    Example:

    ```mlir
       linalg.yield %f0, %f1 : f32, f32
    ```
  }];
}

#endif // LINALG_OPS
