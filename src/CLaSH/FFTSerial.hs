--TODO: tests
module CLaSH.FFTSerial (
    fftSerialStep,
    fftSerial
    ) where

import CLaSH.Prelude

import CLaSH.Complex
import CLaSH.FIFO

--Decimation in time
--2^(n + 1) == size of FFT / 2 == number of butterfly input pairs
fftSerialStep
    :: forall n a. (KnownNat n, Num a)
    => Vec (2 ^ (n + 1)) (Complex a)
    -> Signal Bool
    -> Signal (Complex a, Complex a) 
    -> Signal (Complex a, Complex a)
fftSerialStep twiddles en input = bundle (butterflyHighOutput, butterflyLowOutput)
    where

    counter :: Signal (BitVector (n + 1))
    counter = regEn 0 en (counter + 1)

    (stage' :: Signal (BitVector 1), address' :: Signal (BitVector n)) = unbundle $ split <$> counter

    stage :: Signal Bool
    stage = unpack <$> stage'

    address :: Signal (Unsigned n)
    address = unpack <$> address'

    upperData = mux (not <$> regEn False en stage) (regEn 0 en $ fst <$> input) lowerRamReadResult

    lowerData = mux (not <$> regEn False en stage) lowerRamReadResult (regEn 0 en $ fst <$> input)

    lowerRamReadResult = blockRamPow2 (repeat 0 :: Vec (2 ^ n) (Complex a)) address 
        $ mux en (Just <$> bundle (address, snd <$> input)) (pure Nothing)

    upperRamReadResult = blockRamPow2 (repeat 0 :: Vec (2 ^ n) (Complex a)) (regEn 0 en address)
        $ mux en (Just <$> bundle (regEn 0 en address, upperData)) (pure Nothing)

    --Finally, the butterfly
    butterflyHighInput = upperRamReadResult
    butterflyLowInput  = regEn 0 en lowerData

    twiddle  = (twiddles !!) <$> (regEn 0 en $ regEn 0 en (counter - snatToNum (SNat @ (2 ^ n))))
    twiddled = butterflyLowInput * twiddle

    butterflyHighOutput = butterflyHighInput + twiddled
    butterflyLowOutput  = butterflyHighInput - twiddled 


fftSerial
    :: forall a. Num a
    => Vec 4 (Complex a)
    -> Signal Bool
    -> Signal (Complex a, Complex a)
    -> Signal (Complex a, Complex a)
fftSerial twiddles en input = 
    fftSerialStep cexp4 (de . de . de . de $ en) $ 
    fftSerialStep cexp2 (de en) $ 
    fftBase en input

    where

    de = register False

    cexp2 :: Vec 2 (Complex a)
    cexp2 = selectI (SNat @ 0) (SNat @ 2) twiddles

    cexp4 :: Vec 4 (Complex a)
    cexp4 = selectI (SNat @ 0) (SNat @ 1) twiddles

    fftBase :: Signal Bool -> Signal (Complex a, Complex a) -> Signal (Complex a, Complex a)
    fftBase en = regEn (0, 0) en . fmap func
        where
        func (x, y) = (x + y, x - y)
