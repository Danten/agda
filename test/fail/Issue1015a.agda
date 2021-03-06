-- Andreas, 2014-03-27 fixed issue

{-# OPTIONS --copatterns --sized-types #-}

open import Common.Size

record R (i : Size) : Set where
  constructor c
  field
    j : Size< i
    r : R j

data ⊥ : Set where

elim : (i : Size) → R i → ⊥
elim i (c j r) = elim j r

-- elim should be rejected by termination checker.

-- Being accepted, its is translated into
--
--   elim i x = elim (R.j x) (R.r x)
--
-- which is making reduceHead in the injectivity checker
-- produce larger and larger applications of elim.
-- Leading to a stack overflow.

inh : R ∞
R.j inh = ∞
R.r inh = inh

-- inh should also be rejected

