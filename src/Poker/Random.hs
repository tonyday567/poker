{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

-- | Card entropy
module Poker.Random
  ( rvi,
    rvis,
    rviv,
    shuffle,
    vshuffle,
    dealN,
    dealNFlat,
    dealNWith,
    dealTable,
    dealHand,
    dealTableHand,
    rvs52,
    rvHandRank,
    card7s,
    card7sFlat,
    card7sFlatI,
    tables,
    tablesB,
  )
where

import qualified Data.List as List
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import Lens.Micro
import NumHask.Prelude
import Poker.Types

-- $setup
--
-- >>> :set -XOverloadedStrings
-- >>> import qualified Data.Text as Text

-- | uniform random variate of an Enum-style Int
rvi :: (RandomGen g) => Int -> State g Int
rvi n = do
  g <- get
  let (x, g') = uniformR (0, n - 1) g
  put g'
  pure x

-- | finite population n samples without replacement
rvis :: (RandomGen g) => Int -> Int -> State g [Int]
rvis n k = sequence (rvi . (n -) <$> [0 .. (k - 1)])

-- | finite population n samples without replacement
rviv :: (RandomGen g) => Int -> Int -> State g (S.Vector Int)
rviv n k = S.mapM (rvi . (n -)) (S.generate k id)

-- | a valid series of random index values to shuffle a population of 52 enums
--
-- >>> rvs52
-- [48,23,31,15,16,18,17,23,11,31,5,14,30,28,27,2,9,11,27,24,17,0,10,2,2,11,8,2,18,8,11,16,6,14,3,1,6,0,2,11,1,6,3,7,4,1,5,4,2,1,0,0]
rvs52 :: [Int]
rvs52 = flip evalState (mkStdGen 42) $ rvis 52 52

-- | vector perfect shuffle
--
-- >>> shuffle 52 rvs52
-- ([48,23,32,15,17,20,19,28,11,39,5,18,41,38,37,2,12,16,44,40,29,0,21,4,6,26,22,7,45,25,33,46,14,43,9,3,30,1,13,50,10,36,31,49,35,24,51,47,34,27,8,42],[])
shuffle :: Int -> [Int] -> (V.Vector Int, V.Vector Int)
shuffle n =
  foldl'
    ( \(dealt, rem) i ->
        let (x, rem') = cutV rem i in (V.snoc dealt x, rem')
    )
    (V.empty, V.enumFromN 0 n)

-- | cut a vector at n, returning the n'th element, and the truncated vector
cutV :: V.Vector a -> Int -> (a, V.Vector a)
cutV v x =
  ( v V.! x,
    V.unsafeSlice 0 x v <> V.unsafeSlice (x + 1) (n - x - 1) v
  )
  where
    n = V.length v

-- | deal n cards from a fresh, shuffled, standard pack.
--
-- >>> putStrLn $ Text.intercalate "\n" $ fmap short <$> flip evalState (mkStdGen 44) $ replicateM 5 (dealN 5)
-- A♣3♠K♠7♡9♠
-- 9♠7♡2♣Q♢J♣
-- K♢4♣9♢K♠7♠
-- 7♣7♠J♡8♡J♢
-- 5♠Q♣A♣Q♡T♠
dealN :: (RandomGen g) => Int -> State g [Card]
dealN n = fmap toEnum . ishuffle <$> rvis 52 n

-- | isomorphic to shuffle, but keeps track of the sliced out bit.
--
-- > shuffle 52 (take 52 rvs52) == ishuffle rvs52
vshuffle :: S.Vector Int -> S.Vector Int
vshuffle as = go as S.empty
  where
    go :: S.Vector Int -> S.Vector Int -> S.Vector Int
    go as dealt =
      bool
      (go (S.unsafeTail as) (S.snoc dealt x1))
      dealt
      (S.null as)
      where
        x1 = foldl' (\acc d -> bool acc (acc + one) (d <= acc)) (S.unsafeHead as) (sort $ S.toList dealt)

dealNFlat :: (RandomGen g) => Int -> State g CardsS
dealNFlat n = CardsS . S.map fromIntegral . vshuffle <$> rviv 52 n

-- | deal n cards conditional on a list of cards that has already been dealt.
dealNWith :: (RandomGen g) => Int -> [Card] -> State g [Card]
dealNWith n cs = fmap (cs List.!!) . ishuffle <$> rvis (length cs) n

-- | deal n cards given a Hand has been dealt.
--
-- >>> pretty $ flip evalState (mkStdGen 44) $ (dealHand (Paired Ace) 3)
-- 2♡Q♢2♢
dealHand :: (RandomGen g) => Hand -> Int -> State g [Card]
dealHand b n = dealNWith n (deck List.\\ (\(x, y) -> [x, y]) (toRepPair b))

-- | deal a table
dealTable :: (RandomGen g) => TableConfig -> State g Table
dealTable cfg = do
  cs <- dealNFlat (5 + cfg ^. #numPlayers * 2)
  pure $ makeTable cfg (toCards cs)

-- | deal a table given player i has been dealt a B
--
-- >>> pretty $ flip evalState (mkStdGen 44) $ dealTableHand defaultTableConfig 0 (Paired Ace)
-- A♡A♠ 2♡Q♢,2♢9♣6♢5♠8♠,hero: Just 0,o o,9.5 9,0.5 1,0,
dealTableHand :: (RandomGen g) => TableConfig -> Int -> Hand -> State g Table
dealTableHand cfg i b = do
  cs <- dealHand b (5 + (cfg ^. #numPlayers - 1) * 2)
  pure $ makeTable cfg (take (2 * i) cs <> (\(x, y) -> [x, y]) (toRepPair b) <> drop (2 * i) cs)

-- | uniform random variate of HandRank
rvHandRank :: (RandomGen g) => State g HandRank
rvHandRank = do
  g <- get
  let (x, g') = uniformR (0, V.length allHandRanksV - 1) g
  put g'
  pure (allHandRanksV V.! x)

-- * random card generation

-- | random 7-Card list of lists
--
card7s :: Int -> [[Card]]
card7s n = evalState (replicateM n (fmap toEnum . ishuffle <$> rvis 52 7)) (mkStdGen 42)

-- | Flat storable vector of n 7-card sets.
--
-- >>> S.length $ uncards2S $ card7sFlat 100
--
card7sFlat :: Int -> Cards2S
card7sFlat n = Cards2S $ S.convert $ S.map fromIntegral $ mconcat $
  evalState
  (replicateM n (vshuffle <$> rviv 52 7))
  (mkStdGen 42)

-- | flat storable vector of ints, representing n 7-card sets
--
-- uses ishuffle
card7sFlatI :: Int -> Cards2S
card7sFlatI n = Cards2S $ S.fromList $ fmap fromIntegral $ mconcat $
  evalState
  (replicateM n (ishuffle <$> rvis 52 7))
  (mkStdGen 42)

-- | create a list of n dealt tables, with p players
tables :: Int -> Int -> [Table]
tables p n =
  evalState
  (replicateM n
   (dealTable (defaultTableConfig & #numPlayers .~ p)))
  (mkStdGen 42)

-- | create a list of n dealt tables, with p players, where b is dealt to player k
tablesB :: Int -> Hand -> Int -> Int -> [Table]
tablesB p b k n =
  evalState
  (replicateM n
   (dealTableHand (defaultTableConfig & #numPlayers .~ p) k b))
  (mkStdGen 42)
