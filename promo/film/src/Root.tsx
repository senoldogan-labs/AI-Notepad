import { Composition, Folder } from "remotion";
import "./brand";
import { Promo, SCENE_COMPONENTS } from "./Promo";
import { FPS, HEIGHT, SCENE_ORDER, sceneDuration, totalDuration, WIDTH } from "./timeline";

export const RemotionRoot: React.FC = () => (
  <>
    <Folder name="Scenes">
      {SCENE_ORDER.map((scene) => (
        <Composition
          key={scene}
          id={`Scene-${scene}`}
          component={SCENE_COMPONENTS[scene]}
          width={WIDTH}
          height={HEIGHT}
          fps={FPS}
          durationInFrames={sceneDuration(scene)}
        />
      ))}
    </Folder>
    <Composition id="GistsmithPromo" component={Promo} width={WIDTH} height={HEIGHT} fps={FPS} durationInFrames={totalDuration()} />
    <Composition id="GistsmithPromoVertical" component={Promo} width={HEIGHT} height={WIDTH} fps={FPS} durationInFrames={totalDuration()} />
  </>
);
