{-# LANGUAGE DataKinds, TypeOperators, RecursiveDo, BangPatterns #-}
import           Control.Monad
import           Data.IORef
import           Graphics.UI.GLFW
import           Linear
import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.Rendering.OpenGL.Raw as GLRaw
import           Graphics.Rendering.OpenGL (($=), GLfloat)
import qualified Graphics.GLUtil.Camera3D as Camera

import qualified Constants as C
import           Geometry
import           Window (initGL, InputState(..), KeyEvent)
import           Music
import           Code

-- Imports for game logic
import Data.List
import Data.Maybe
import Sound.MIDI.Message.Channel
import System.MIDI
import System.Random
import System.Environment
import System.IO
import qualified Data.EventList.Relative.TimeBody as EL
import qualified Sound.MIDI.File                  as F
import qualified Sound.MIDI.File.Event            as FE
import qualified Sound.MIDI.File.Load             as FL
import qualified Sound.MIDI.Message.Channel.Voice as MCV

type Music = [Note]
type PlaybackData = [(Double, FE.T)]

data Renderables = Renderables {
        renderBoard :: M44 GLfloat -> IO (),
        renderMarker :: M44 GLfloat -> M44 GLfloat -> V3 GLfloat -> IO (),
        renderMarkerDamage :: M44 GLfloat -> M44 GLfloat -> V4 GLfloat -> IO (),
        renderNote :: M44 GLfloat -> M44 GLfloat -> V3 GLfloat -> IO ()
    }

data GameState = GameState {
        progress      :: IORef Time,
        music         :: IORef Music,
        playback      :: IORef PlaybackData,
        connection    :: Maybe Connection,
        tokens        :: IORef [Code],
        finishingTime :: Time,
        f1Size        :: IORef GLfloat,
        f2Size        :: IORef GLfloat,
        f3Size        :: IORef GLfloat,
        f4Size        :: IORef GLfloat,
        f1Damage      :: IORef GLfloat,
        f2Damage      :: IORef GLfloat,
        f3Damage      :: IORef GLfloat,
        f4Damage      :: IORef GLfloat,
        f1Pressed     :: IORef Bool,
        f2Pressed     :: IORef Bool,
        f3Pressed     :: IORef Bool,
        f4Pressed     :: IORef Bool,
        renderables   :: Renderables,
        projMatrix    :: M44 GLfloat
    }

-- Turn from relative times to absolute times in the fst of the tuples
accumTimes :: Num t => [(t, a)] -> [(t, a)]
accumTimes xs
    = snd $ foldl' (\(!v, !acc) (!val, !a') ->
        (val + v, (val + v, a') : acc)) (0, []) xs

loadMusic :: FilePath -> IO (Music, PlaybackData)
loadMusic file = do
    tracks <- F.getTracks <$> FL.fromFile file
    let events = sort $ concatMap (accumTimes . EL.toPairList) tracks
        filtered = reverse . fst $ foldl' (\(!acc, !lt) e@(!t, !ev)
                                    -> if lt + 185 < t
                                           then (e : acc, t)
                                           else (acc, lt)) ([], 0) events
    fs <- catMaybes <$!> mapM fromEvent filtered
    return (fs, map (\(f, s) -> (fromIntegral f / 1000, s)) events)

fromEvent :: (FE.ElapsedTime, FE.T) -> IO (Maybe Note)
fromEvent (t, FE.MIDIEvent (Cons ch _)) = do
    r <- randomRIO (0, 3) :: IO Int
    let a = if r == 0 then 1 else 0
        ch' = (fromChannel ch + a) `mod` 4
    return $ Just $ Note (fromIntegral t / 1000, toEnum ch')
fromEvent _ = return Nothing

playNote :: Maybe Connection -> FE.T -> IO ()
playNote (Just connection) (FE.MIDIEvent (Cons ch body))
    = play ch body connection
playNote _ _ = return ()

play :: Channel -> Body -> Connection -> IO ()
play ch (Voice (MCV.NoteOn p v)) conn
    = send conn (MidiMessage (fromChannel ch) (NoteOn (fromPitch p) (fromVelocity v)))
play ch (Voice (MCV.NoteOff p v)) conn
    = send conn (MidiMessage (fromChannel ch) (NoteOff (fromPitch p) (fromVelocity v)))
play _ _ _ = return ()


getLength :: Music -> Time
getLength notes = time
    where
        Note (time, _) = last notes

translateMatrix :: GLfloat -> GLfloat -> GLfloat -> M44 GLfloat
translateMatrix x y z = mkTransformationMat identity (V3 x y z)

scaleMatrix :: GLfloat -> GLfloat -> GLfloat -> M44 GLfloat
scaleMatrix x y z = V4 (V4 x 0 0 0) (V4 0 y 0 0) (V4 0 0 z 0) (V4 0 0 0 1)

-- Takes a list of notes which have not been missed already
checkHit :: Music -> Time -> Beat -> Bool
checkHit music elapsed beat = beat == b && (t - elapsed) < C.timeToCatch
    where
        Note (t, b) = head music

printNextToken :: GameState -> IO ()
printNextToken state = do
    toks <- readIORef (tokens state)
    case toks of
      (Indent i : ts) -> putStr i >> writeIORef (tokens state) ts
      (Token t : ts) -> do
          putStr t
          writeIORef (tokens state) ts
          printNextToken state
      [] -> return ()

loop :: [Code] -> IO ()
loop [] = return ()
loop (Indent i : cs) = putStr i >> loop cs
loop (Token t : cs) = getChar >> putStr t >> loop cs

-- Missed note
missedNote :: GameState -> Beat -> IO ()
missedNote state F1 = writeIORef (f1Damage state) 1
missedNote state F2 = writeIORef (f2Damage state) 1
missedNote state F3 = writeIORef (f3Damage state) 1
missedNote state F4 = writeIORef (f4Damage state) 1

dropExpiredWhile :: GameState -> (Note -> Bool) -> [Note] -> IO [Note]
dropExpiredWhile _ _ [] = return []
dropExpiredWhile state pred all@(n@(Note (_, b)):ns) =
        if pred n then do
            missedNote state b
            dropExpiredWhile state pred ns
        else
            return all

keyDownEvent :: GameState -> KeyEvent
keyDownEvent state key
    | key `elem` [Key'F1, Key'F2, Key'F3, Key'F4] = do
        enlargeMarker key
        writeIORef (keyPressed key $ state) True
        --musicState <- readIORef $ music state
        --elapsed <- readIORef $ progress state
        --when (checkHit musicState elapsed (mapKey key)) $ do
        --    printNextToken state
        --    modifyIORef' (music state) tail
    | key == Key'Enter = do
        musicState <- readIORef $ music state
        elapsed <- readIORef $ progress state
        f1p <- readIORef (f1Pressed state)
        when (f1p && checkHit musicState elapsed F1) hit
        f2p <- readIORef (f2Pressed state)
        when (f2p && checkHit musicState elapsed F2) hit
        f3p <- readIORef (f3Pressed state)
        when (f3p && checkHit musicState elapsed F3) hit
        f4p <- readIORef (f4Pressed state)
        when (f4p && checkHit musicState elapsed F4) hit
    | otherwise = return ()
    where
        hit = do
            printNextToken state
            modifyIORef' (music state) tail
        mapKey Key'F1 = F1
        mapKey Key'F2 = F2
        mapKey Key'F3 = F3
        mapKey Key'F4 = F4
        keyPressed Key'F1 = f1Pressed
        keyPressed Key'F2 = f2Pressed
        keyPressed Key'F3 = f3Pressed
        keyPressed Key'F4 = f4Pressed
        enlargeMarker Key'F1 = writeIORef (f1Size state) C.markerScale
        enlargeMarker Key'F2 = writeIORef (f2Size state) C.markerScale
        enlargeMarker Key'F3 = writeIORef (f3Size state) C.markerScale
        enlargeMarker Key'F4 = writeIORef (f4Size state) C.markerScale
        enlargeMarker _ = undefined

keyUpEvent :: GameState -> KeyEvent
keyUpEvent state key
    | key `elem` [Key'F1, Key'F2, Key'F3, Key'F4] = do
        writeIORef (keyPressed key $ state) False
    | otherwise = return ()
    where
        keyPressed Key'F1 = f1Pressed
        keyPressed Key'F2 = f2Pressed
        keyPressed Key'F3 = f3Pressed
        keyPressed Key'F4 = f4Pressed

main :: IO ()
main = mdo
    -- Load the music
    [midiFile, source] <- getArgs
    ds <- enumerateDestinations
    conn <- case ds of
        (destination : _) -> do
            c <- openDestination destination
            start c
            return $ Just c
        _ -> return Nothing
    (music, playback) <- loadMusic midiFile

    hSetEcho stdin False
    hSetBuffering stdin NoBuffering
    hSetBuffering stdout NoBuffering
    toks <- loadTokens source

    -- Create the window and store the window upate function
    -- state doesn't actually exist at this point, but mdo saves us here so
    -- whatever
    updateWindow <- initGL "Programmer Hero" C.width C.height (keyDownEvent state) (keyUpEvent state)

    -- Set up rendering settings
    GL.clearColor $= C.backgroundColour
    GL.depthFunc $= Just GL.Lequal
    GL.blend $= GL.Enabled
    GL.blendFunc $= (GL.SrcAlpha, GL.OneMinusSrcAlpha)

    -- Build scene and store entity render functions
    renderables <- Renderables <$> buildBoard <*> buildMarker <*> buildMarkerDamage <*> buildNote

    -- Calculate the projection matrix
    let aspect = (fromIntegral C.width) / (fromIntegral C.height)
    let projMatrix = Camera.projectionMatrix (Camera.deg2rad 30) aspect 0.1 500

    -- Set up the game state
    musicRef <- newIORef music
    progressRef <- newIORef 0.0
    playbackRef <- newIORef playback
    tokRef <- newIORef toks
    f1Ref <- newIORef 1.0
    f2Ref <- newIORef 1.0
    f3Ref <- newIORef 1.0
    f4Ref <- newIORef 1.0
    f1Damage <- newIORef 0.0
    f2Damage <- newIORef 0.0
    f3Damage <- newIORef 0.0
    f4Damage <- newIORef 0.0
    f1Pressed <- newIORef False
    f2Pressed <- newIORef False
    f3Pressed <- newIORef False
    f4Pressed <- newIORef False
    let state = GameState progressRef
                          musicRef
                          playbackRef
                          conn
                          tokRef
                          (getLength music)
                          f1Ref f2Ref f3Ref f4Ref
                          f1Damage f2Damage f3Damage f4Damage
                          f1Pressed f2Pressed f3Pressed f4Pressed
                          renderables
                          projMatrix

    -- Kick off the main loop
    mainLoop camera updateWindow state
    case conn of
        Just c -> do
            stop c
            close c
        _ -> return ()
    where
        -- Render Function
        render :: GameState -> M44 GLfloat -> IO ()
        render state viewProjMatrix = do
            -- Disable depth buffering
            GLRaw.glDisable GLRaw.gl_DEPTH_TEST

            -- Render the board
            renderBoard (renderables state) viewProjMatrix

            let xoffset F1 = -1.5
                xoffset F2 = -0.5
                xoffset F3 = 0.5
                xoffset F4 = 1.5
                scaleDown x = (x - 1.0) * 0.9 + 1.0
                fadeOut x = max (x - 0.05) 0

            -- Update animations
            f1p <- readIORef (f1Pressed state)
            unless f1p $
                modifyIORef' (f1Size state) scaleDown
            f2p <- readIORef (f2Pressed state)
            unless f2p $
                modifyIORef' (f2Size state) scaleDown
            f3p <- readIORef (f3Pressed state)
            unless f3p $
                modifyIORef' (f3Size state) scaleDown
            f4p <- readIORef (f4Pressed state)
            unless f4p $
                modifyIORef' (f4Size state) scaleDown
            modifyIORef' (f1Damage state) fadeOut
            modifyIORef' (f2Damage state) fadeOut
            modifyIORef' (f3Damage state) fadeOut
            modifyIORef' (f4Damage state) fadeOut
            f1CurSize <- readIORef (f1Size state)
            f2CurSize <- readIORef (f2Size state)
            f3CurSize <- readIORef (f3Size state)
            f4CurSize <- readIORef (f4Size state)
            f1DamageAlpha <- readIORef (f1Damage state)
            f2DamageAlpha <- readIORef (f2Damage state)
            f3DamageAlpha <- readIORef (f3Damage state)
            f4DamageAlpha <- readIORef (f4Damage state)
            
            -- Render the markers for each colour
            forM_ [F1, F2, F3, F4] $ \beat -> do
                let x = xoffset beat * C.markerRegion
                
                -- Render Marker Damage
                let v3tov4 (V3 r g b) a = V4 r g b a
                    damageAlpha F1 = f1DamageAlpha
                    damageAlpha F2 = f2DamageAlpha
                    damageAlpha F3 = f3DamageAlpha
                    damageAlpha F4 = f4DamageAlpha
                    damageColour = v3tov4 (C.getBeatColours beat) (damageAlpha beat)
                    damageMatrix = translateMatrix x 0 0
                renderMarkerDamage (renderables state) viewProjMatrix damageMatrix damageColour
                
                -- Render Marker
                let scale F1 = f1CurSize
                    scale F2 = f2CurSize
                    scale F3 = f3CurSize
                    scale F4 = f4CurSize
                    scaleSize = scale beat
                    modelMatrix = (translateMatrix x 0 ((C.boardLength / 2) - (C.markerSize / 2))) !*! (scaleMatrix scaleSize scaleSize scaleSize)
                renderMarker (renderables state) viewProjMatrix modelMatrix (C.getBeatColours beat)

            -- Drop notes which have already been played
            elapsed <- realToFrac <$> readIORef (progress state)
            currentMusic <- readIORef $ music state
            filteredMusic <- dropExpiredWhile state (\(Note (t, _)) -> elapsed >= t) currentMusic
            writeIORef (music state) filteredMusic

            -- Enable depth buffering
            GLRaw.glEnable GLRaw.gl_DEPTH_TEST

            -- Render a note for each note in the song
            currentMusic <- readIORef (music state)
            forM_ currentMusic $ \(Note (time, note)) -> do
                elapsed <- realToFrac <$> readIORef (progress state)
                let x = xoffset note * C.noteSpeed
                    distance = (elapsed - (realToFrac time)) * C.markerSize / C.timeToCatch
                    modelMatrix = translateMatrix x 0 (distance + C.boardLength / 2 - C.markerRegion / 2)
                renderNote (renderables state) viewProjMatrix modelMatrix (C.getBeatColours note)

        -- Main Loop
        mainLoop :: Camera.Camera GLfloat -> IO InputState -> GameState -> IO ()
        mainLoop c updateWindow state = do
            windowState <- updateWindow

            -- UPDATE
            -- Increment the timer
            modifyIORef' (progress state) (+ timeStep windowState)

            progress' <- readIORef (progress state)
            playAllDue progress' state

            -- RENDER
            -- Clear framebuffer
            GL.clear [GL.ColorBuffer, GL.DepthBuffer]

            -- Calculate view and projection matrices
            let viewMatrix = Camera.camMatrix c

            -- Draw using render parameters
            render state (projMatrix state !*! viewMatrix)

            -- Check win condition
            remMusic <- readIORef . music $ state
            when (null remMusic) $
              putStrLn "You won"

            -- Quit if escaped has been pressed
            unless (null remMusic || shouldQuit windowState) $
              mainLoop c updateWindow state
        camera = Camera.tilt (-20) $ Camera.dolly (V3 0 16 64) Camera.fpsCamera
        playAllDue :: Time -> GameState -> IO ()
        playAllDue progress state = do
            es <- readIORef (playback state)
            let (abstime, event) = head es
            when (abstime <= progress) $ do
                playNote (connection state) event
                modifyIORef' (playback state) tail
                playAllDue progress state

