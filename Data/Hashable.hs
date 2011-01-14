{-# LANGUAGE BangPatterns, CPP, ForeignFunctionInterface, MagicHash #-}

------------------------------------------------------------------------
-- |
-- Module      :  Data.Hash
-- Copyright   :  (c) Milan Straka 2010
--                (c) Johan Tibell 2011
-- License     :  BSD-style
-- Maintainer  :  fox@ucw.cz
-- Stability   :  provisional
-- Portability :  portable
--
-- This module defines a class, 'Hashable', for types that can be
-- converted to a hash value.  This class exists for the benefit of
-- hashing-based data structures.  The module provides instances for
-- basic types and a way to combine hash values.
--
-- The 'hash' function should be as collision-free as possible, which
-- means that the 'hash' function must map the inputs to the hash
-- values as evenly as possible.

module Data.Hashable
    (
      -- * Computing hash values
      Hashable(..)

      -- * Creating new instances
      -- $blocks
    , hashPtr
#if defined(__GLASGOW_HASKELL__)
    , hashByteArray
#endif
    , combine
    ) where

import Data.Bits (bitSize, shiftL, shiftR, xor)
import Data.Int (Int8, Int16, Int32, Int64)
import Data.Word (Word, Word8, Word16, Word32, Word64)
import Data.List (foldl')
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BL
import Foreign.C (CInt, CString)
import Foreign.Ptr (Ptr, castPtr)

#if defined(__GLASGOW_HASKELL__)
import GHC.Base (ByteArray#, Int(..), indexWord8Array#)
import GHC.Word (Word8(..))
#endif

------------------------------------------------------------------------
-- * Computing hash values

-- | The class of types that can be converted to a hash value.
class Hashable a where
    -- | Return a hash value for the argument.
    --
    -- The general contract of 'hash' is:
    --
    --  * This integer need not remain consistent from one execution
    --    of an application to another execution of the same
    --    application.
    --
    --  * If two values are equal according to the '==' method, then
    --    applying the 'hash' method on each of the two values must
    --    produce the same integer result.
    --
    --  * It is /not/ required that if two values are unequal
    --    according to the '==' method, then applying the 'hash'
    --    method on each of the two values must produce distinct
    --    integer results.  However, the programmer should be aware
    --    that producing distinct integer results for unequal values
    --    may improve the performance of hashing-based data
    --    structures.
    hash :: a -> Int

instance Hashable () where hash _ = 0

instance Hashable Bool where hash x = case x of { True -> 1; False -> 0 }

instance Hashable Int where hash = id
instance Hashable Int8 where hash = fromIntegral
instance Hashable Int16 where hash = fromIntegral
instance Hashable Int32 where hash = fromIntegral
instance Hashable Int64 where
    hash n
        | bitSize n == 64 = fromIntegral n
        | otherwise = fromIntegral (fromIntegral n `xor`
                                   (fromIntegral n `shiftR` 32 :: Word64))

instance Hashable Word where hash = fromIntegral
instance Hashable Word8 where hash = fromIntegral
instance Hashable Word16 where hash = fromIntegral
instance Hashable Word32 where hash = fromIntegral
instance Hashable Word64 where
    hash n
        | bitSize n == 64 = fromIntegral n
        | otherwise = fromIntegral (n `xor` (n `shiftR` 32))

instance Hashable Char where hash = fromEnum

instance Hashable a => Hashable (Maybe a) where
    hash Nothing = 0
    hash (Just a) = 1 `combine` hash a

instance (Hashable a, Hashable b) => Hashable (Either a b) where
    hash (Left a)  = 0 `combine` hash a
    hash (Right b) = 1 `combine` hash b

instance (Hashable a1, Hashable a2) => Hashable (a1, a2) where
    hash (a1, a2) = hash a1 `combine` hash a2

instance (Hashable a1, Hashable a2, Hashable a3) => Hashable (a1, a2, a3) where
    hash (a1, a2, a3) = hash a1 `combine` hash a2 `combine` hash a3

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4) =>
         Hashable (a1, a2, a3, a4) where
    hash (a1, a2, a3, a4) = hash a1 `combine` hash a2 `combine` hash a3
                            `combine` hash a4

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5)
      => Hashable (a1, a2, a3, a4, a5) where
    hash (a1, a2, a3, a4, a5) =
        hash a1 `combine` hash a2 `combine` hash a3 `combine` hash a4 `combine`
        hash a5

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5,
          Hashable a6) => Hashable (a1, a2, a3, a4, a5, a6) where
    hash (a1, a2, a3, a4, a5, a6) =
        hash a1 `combine` hash a2 `combine` hash a3 `combine` hash a4 `combine`
        hash a5 `combine` hash a6

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5,
          Hashable a6, Hashable a7) =>
         Hashable (a1, a2, a3, a4, a5, a6, a7) where
    hash (a1, a2, a3, a4, a5, a6, a7) =
        hash a1 `combine` hash a2 `combine` hash a3 `combine` hash a4 `combine`
        hash a5 `combine` hash a6 `combine` hash a7

instance Hashable a => Hashable [a] where
    {-# SPECIALIZE instance Hashable [Char] #-}
    hash = foldl' hashAndCombine 0

hashAndCombine :: Hashable h => Int -> h -> Int
hashAndCombine acc h = acc `combine` hash h

instance Hashable B.ByteString where
    hash bs = B.inlinePerformIO $
              B.unsafeUseAsCStringLen bs $ \(p, len) ->
              hashPtr p (fromIntegral len)

instance Hashable BL.ByteString where hash = BL.foldlChunks hashAndCombine 0

------------------------------------------------------------------------
-- * Creating new instances

-- $blocks
--
-- These functions can be used when creating new instances of
-- 'Hashable'.  For example, the 'hash' method for many string-like
-- types can be defined in terms of either 'hashPtr' or
-- 'hashByteArray'.  Here's how you could implement an instance for
-- the 'B.ByteString' data type, from the @bytestring@ package:
--
-- > import qualified Data.ByteString as B
-- > import qualified Data.ByteString.Internal as B
-- > import qualified Data.ByteString.Unsafe as B
-- > import Data.Hashable
-- > import Foreign.Ptr (castPtr)
-- >
-- > instance Hashable B.ByteString where
-- >     hash bs = B.inlinePerformIO $
-- >               B.unsafeUseAsCStringLen bs $ \ (p, len) ->
-- >               hashPtr p (fromIntegral len)

-- | Compute a hash value for the content of this pointer.
hashPtr :: Ptr a      -- ^ pointer to the data to hash
        -> Int        -- ^ length, in bytes
        -> IO Int     -- ^ hash value
hashPtr p len =
    fromIntegral `fmap` hashByteString (castPtr p) (fromIntegral len)

#if defined(__GLASGOW_HASKELL__)
-- | Compute a hash value for the content of this 'ByteArray#',
-- beginning at the specified offset, using specified number of bytes.
-- Availability: GHC.
hashByteArray :: ByteArray#  -- ^ data to hash
              -> Int         -- ^ offset, in bytes
              -> Int         -- ^ length, in bytes
              -> Int         -- ^ hash value
hashByteArray ba0 off len = go ba0 off len 0
  where
    -- Bernstein's hash
    go :: ByteArray# -> Int -> Int -> Int -> Int
    go !ba !i !n !h
        | i < n = let h' = (h + h `shiftL` 5) `xor`
                           (fromIntegral $ unsafeIndexWord8 ba i)
                  in go ba (i + 1) n h'
        | otherwise = h

-- | Unchecked read of an immutable array.  May return garbage or
-- crash on an out-of-bounds access.
unsafeIndexWord8 :: ByteArray# -> Int -> Word8
unsafeIndexWord8 ba (I# i#) =
    case indexWord8Array# ba i# of r# -> (W8# r#)
{-# INLINE unsafeIndexWord8 #-}
#endif

-- | Combine two given hash values.
--
-- You can use this function to implement 'Hashable' instances for
-- your own types, using this recipe:
--
-- > instance (Hashable a, Hashable b) => Hashable (Foo a b) where
-- >     hash (Foo a b) = 17 `combine` hash a `combine` hash b
--
-- A nonzero seed is used so the hash value will be affected by
-- initial fields whose hash value is zero.  If no seed was provided,
-- the overall hash value would be unaffected by any such initial
-- fields, which could increase collisions.  The value 17 is
-- arbitrary.

combine :: Int -> Int -> Int
combine h1 h2 = (h1 + h1 `shiftL` 5) `xor` h2

------------------------------------------------------------------------
-- * Foreign imports

foreign import ccall unsafe hashByteString :: CString -> CInt -> IO CInt
