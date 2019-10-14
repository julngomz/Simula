{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE DataKinds #-}

module Plugin.SimulaCanvasItem where

import Control.Exception

import Data.Colour
import Data.Colour.SRGB.Linear

import Control.Monad
import Data.Coerce
import Unsafe.Coerce

import           Linear
import           Plugin.Imports

import           Godot.Extra.Register
import           Godot.Core.GodotGlobalConstants
import qualified Godot.Core.GodotRigidBody   as RigidBody
import           Godot.Gdnative.Internal.Api
import qualified Godot.Methods               as G
import qualified Godot.Gdnative.Internal.Api as Api

import Plugin.Types
import Data.Maybe
import Data.Either

import           Foreign
import           Foreign.Ptr
import           Foreign.Marshal.Alloc
import           Foreign.C.Types
import qualified Language.C.Inline as C

import           Control.Lens                hiding (Context)

import Data.Typeable

import qualified Data.Map.Strict as M

instance Eq GodotSimulaCanvasItem where
  (==) = (==) `on` _gsciObject

instance GodotClass GodotSimulaCanvasItem where
  godotClassName = "SimulaCanvasItem"

instance ClassExport GodotSimulaCanvasItem where
  classInit obj = do
    GodotSimulaCanvasItem obj
                  <$> atomically (newTVar (error "Failed to initialize GodotSimulaCanvasItem."))
                  <*> atomically (newTVar (error "Failed to initialize GodotSimulaCanvasItem."))
  classExtends = "Node2D" -- "RigidBody2D" -- "CanvasItem"
  classMethods =
    [
      GodotMethod NoRPC "_process" Plugin.SimulaCanvasItem._process
    , GodotMethod NoRPC "_draw" Plugin.SimulaCanvasItem._draw
    ]

instance HasBaseClass GodotSimulaCanvasItem where
  type BaseClass GodotSimulaCanvasItem = GodotCanvasItem
  super (GodotSimulaCanvasItem obj _ _ ) = GodotCanvasItem obj

newGodotSimulaCanvasItem :: GodotSimulaViewSprite -> IO (GodotSimulaCanvasItem)
newGodotSimulaCanvasItem gsvs = do
  gsci <- "res://addons/godot-haskell-plugin/SimulaCanvasItem.gdns"
    & newNS' []
    >>= godot_nativescript_get_userdata
    >>= deRefStablePtr . castPtrToStablePtr :: IO GodotSimulaCanvasItem

  viewport <- initializeRenderTarget gsvs
  atomically $ writeTVar (_gsciGSVS gsci) gsvs
  atomically $ writeTVar (_gsciViewport gsci) viewport
  -- G.set_process grt False

  return gsci

getCoordinatesFromCenter :: GodotWlrSurface -> Int -> Int -> IO GodotVector2
getCoordinatesFromCenter wlrSurface sx sy = do
  -- putStrLn "getCoordinatesFromCenter"
  (bufferWidth', bufferHeight')    <- getBufferDimensions wlrSurface
  let (bufferWidth, bufferHeight)  = (fromIntegral bufferWidth', fromIntegral bufferHeight')
  let (fromTopLeftX, fromTopLeftY) = (fromIntegral sx, fromIntegral sy)
  let fromCenterX                  = -(bufferWidth/2) + fromTopLeftX
  let fromCenterY                  = -(-(bufferHeight/2) + fromTopLeftY)
  -- NOTE: In godotston fromCenterY is isn't negative, but since we set
  -- `G.render_target_v_flip viewport True` we can set this
  -- appropriately
  let v2 = (V2 fromCenterX fromCenterY) :: V2 Float
  gv2 <- toLowLevel v2 :: IO GodotVector2
  return gv2

useSimulaCanvasItemToDrawSubsurfaces :: GodotSimulaViewSprite -> IO ()
useSimulaCanvasItemToDrawSubsurfaces gsvs  = do
  -- putStrLn "useSimulaCanvasItemToDrawParentSurface"
  simulaView <- readTVarIO (gsvs ^. gsvsView)
  let eitherSurface = (simulaView ^. svWlrEitherSurface)
  wlrSurface <- getWlrSurface eitherSurface
  sprite3D <- readTVarIO (gsvs ^. gsvsSprite)
  gsci <- readTVarIO (gsvs ^. gsvsSimulaCanvasItem)
  viewport <- readTVarIO (gsci ^. gsciViewport)
  viewportTexture <- G.get_texture viewport

  rid <- G.get_rid viewportTexture
  visualServer <- getSingleton GodotVisualServer "VisualServer"
  G.texture_set_flags visualServer rid 7 -- Set to 6 if you see gradient issues
  G.set_texture sprite3D (safeCast viewportTexture)

  G.send_frame_done wlrSurface

  return ()

_process :: GFunc GodotSimulaCanvasItem
_process self args = do
  -- putStrLn "_process"
  G.update self
  retnil


improveTextureQuality :: GodotTexture -> IO ()
improveTextureQuality texture = do
  if ((unsafeCoerce texture) /= nullPtr)
    then do rid <- G.get_rid texture
            -- rid_canvas <- G.get_canvas self
            -- rid_canvas_item <- G.get_canvas self
            visualServer <- getSingleton GodotVisualServer "VisualServer"
            G.texture_set_flags visualServer rid 7
            -- G.texture_set_flags visualServer rid_canvas 6
            -- G.texture_set_flags visualServer rid_canvas_item 6
  else return ()

_draw :: GFunc GodotSimulaCanvasItem
_draw self _ = do
  -- putStrLn "_draw"
  gsvs <- readTVarIO (self ^. gsciGSVS)
  sprite3D <- readTVarIO (gsvs ^. gsvsSprite)
  simulaView <- readTVarIO (gsvs ^. gsvsView)
  let eitherSurface = (simulaView ^. svWlrEitherSurface)
  children <- case eitherSurface of
    Left wlrXdgSurface -> return []
    Right wlrXWaylandSurface -> do
      -- putStrLn "# Parent Properties"
      G.print_xwayland_surface_properties wlrXWaylandSurface
      arrayOfChildren <- G.get_children wlrXWaylandSurface :: IO GodotArray
      numChildren <- Api.godot_array_size arrayOfChildren
      -- putStrLn $ "Number of children (from Haskell): " ++ (show numChildren) -- Alternates between correct value and 0, just like in C++
      -- arrayOfChildrenGV <- (if numChildren /= 0 then fromLowLevel arrayOfChildren else return [])
      --arrayOfChildrenGV <- fromLowLevel arrayOfChildren :: IO [GodotVariant] --
      arrayOfChildrenGV <- fromLowLevel' arrayOfChildren
      children <- mapM fromGodotVariant arrayOfChildrenGV :: IO [GodotWlrXWaylandSurface]
      return children
  wlrSurface <- getWlrSurface eitherSurface
  parentWlrTexture <- G.get_texture wlrSurface

  let isNull = ((unsafeCoerce parentWlrTexture) == nullPtr)
  case isNull of
        True -> putStrLn "Texture is null!"
        False -> do renderPosition <- toLowLevel (V2 0 0) :: IO GodotVector2
                    textureToDraw <- G.get_texture wlrSurface :: IO GodotTexture
                    gsci <- readTVarIO (gsvs ^. gsvsSimulaCanvasItem)

                    godotColor <- (toLowLevel $ (rgb 1.0 1.0 1.0) `withOpacity` 1) :: IO GodotColor
                    G.draw_texture gsci textureToDraw renderPosition godotColor (coerce nullPtr)

                    -- Improve texture quality
                    improveTextureQuality parentWlrTexture
                    mapM drawChild children
                    return ()
                    -- G.draw_texture gsci textureToDraw renderPosition2 godotColor (coerce nullPtr) -- nullTexture
  retnil
  where
    -- Fixes a the bug from godot-haskell/godot-extra's `instance GodotFFI GodotArray [GodotVariant]`
    fromLowLevel' vs = do
      size <- fromIntegral <$> Api.godot_array_size vs
      forM [0..size-1] $ Api.godot_array_get vs
    drawChild :: GodotWlrXWaylandSurface -> IO ()
    drawChild wlrXWaylandSurface = do
           -- putStrLn "## Child Properties"
           G.print_xwayland_surface_properties wlrXWaylandSurface
           surface <- G.get_wlr_surface wlrXWaylandSurface
           -- let isNull = ((unsafeCoerce subsurfaceTexture) == nullPtr)
           let isNull = ((unsafeCoerce surface) == nullPtr)
           case isNull of
                 True -> putStrLn "Child texture is null!"
                 False -> do subsurfaceTexture <- G.get_texture surface :: IO GodotTexture
                             improveTextureQuality subsurfaceTexture

                             x <- G.get_x wlrXWaylandSurface
                             y <- G.get_y wlrXWaylandSurface

                             subsurfaceRenderPosition <- toLowLevel (V2 (fromIntegral x) (fromIntegral y)) :: IO GodotVector2
                             -- subsurfaceRenderPosition' <- getCoordinatesFromCenter surface x y
                             godotColor <- (toLowLevel $ (rgb 1.0 1.0 1.0) `withOpacity` 1) :: IO GodotColor
                             G.draw_texture self subsurfaceTexture subsurfaceRenderPosition godotColor (coerce nullPtr)
           return ()

initializeRenderTarget :: GodotSimulaViewSprite -> IO (GodotViewport)
initializeRenderTarget gsvs = do
  simulaView <- readTVarIO (gsvs ^. gsvsView)
  let eitherSurface = (simulaView ^. svWlrEitherSurface)
  wlrSurface <- getWlrSurface eitherSurface

  -- putStrLn "initializeRenderTarget"
  -- "When we are drawing to a Viewport that is not the Root, we call it a
  --  render target." -- Godot documentation"
  renderTarget <- unsafeInstance GodotViewport "Viewport"
  -- No need to add the Viewport to the SceneGraph since we plan to use it as a render target
    -- G.set_name viewport =<< toLowLevel "Viewport"
    -- G.add_child gsvs ((safeCast viewport) :: GodotObject) True

  G.set_disable_input renderTarget True -- Turns off input handling

  G.set_usage renderTarget 0 -- USAGE_2D = 0
  -- G.set_hdr renderTarget False -- Might be useful to disable HDR rendering for performance in the future (requires upgrading gdwlroots to GLES3)

  -- "Every frame, the Viewport’s texture is cleared away with the default clear
  -- color (or a transparent color if Transparent BG is set to true). This can
  -- be changed by setting Clear Mode to Never or Next Frame. As the name
  -- implies, Never means the texture will never be cleared, while next frame
  -- will clear the texture on the next frame and then set itself to Never."
  --
  --   CLEAR_MODE_ALWAYS = 0
  --   CLEAR_MODE_NEVER = 1
  -- 
  G.set_clear_mode renderTarget 1

  -- "By default, re-rendering of the Viewport happens when the Viewport’s
  -- ViewportTexture has been drawn in a frame. If visible, it will be rendered;
  -- otherwise, it will not. This behavior can be changed to manual rendering
  -- (once), or always render, no matter if visible or not. This flexibility
  -- allows users to render an image once and then use the texture without
  -- incurring the cost of rendering every frame."
  --
  -- UPDATE_DISABLED = 0 — Do not update the render target.
  -- UPDATE_ONCE = 1 — Update the render target once, then switch to UPDATE_DISABLED.
  -- UPDATE_WHEN_VISIBLE = 2 — Update the render target only when it is visible. This is the default value.
  -- UPDATE_ALWAYS = 3 — Always update the render target. 
  G.set_update_mode renderTarget 3

  -- "Note that due to the way OpenGL works, the resulting ViewportTexture is flipped vertically. You can use Image.flip_y on the result of Texture.get_data to flip it back[or you can also use set_vflip]:" -- Godot documentation
  G.set_vflip renderTarget True -- In tutorials this is set as True, but no reference to it in Godotston; will set to True for now

  -- We could alternatively set the size of the renderTarget via set_size_override [and set_size_override_stretch]
  dimensions@(width, height) <- getBufferDimensions wlrSurface
  pixelDimensionsOfWlrSurface <- toGodotVector2 dimensions

  -- Here I'm attempting to set the size of the viewport to the pixel dimensions
  -- of our wlrXdgSurface argument:
  G.set_size renderTarget pixelDimensionsOfWlrSurface

  -- There is, however, an additional way to do this and I'm not sure which one
  -- is better/more idiomatic:
    -- G.set_size_override renderTarget True vector2
    -- G.set_size_override_stretch renderTarget True

  return renderTarget
  where
        -- | Used to supply GodotVector2 to
        -- |   G.set_size :: GodotViewport -> GodotVector2 -> IO ()
        toGodotVector2 :: (Int, Int) -> IO (GodotVector2)
        toGodotVector2 (width, height) = do
          let v2 = (V2 (fromIntegral width) (fromIntegral height))
          gv2 <- toLowLevel v2 :: IO (GodotVector2)
          return gv2

getBufferDimensions :: GodotWlrSurface -> IO (Int, Int)
getBufferDimensions wlrSurface = do
  wlrSurfaceState <- G.get_current_state wlrSurface -- isNull: False
  bufferWidth <- G.get_buffer_width wlrSurfaceState
  bufferHeight <- G.get_buffer_height wlrSurfaceState
  width <- G.get_width wlrSurfaceState
  height <-G.get_height wlrSurfaceState
  -- putStrLn $ "getBufferDimensions (buffer width/height): (" ++ (show bufferWidth) ++ "," ++ (show bufferHeight) ++ ")"
  -- putStrLn $ "getBufferDimensions (width/height): (" ++ (show width) ++ "," ++ (show height) ++ ")"
  return (bufferWidth, bufferHeight) -- G.set_size expects "the width and height of viewport" according to Godot documentation