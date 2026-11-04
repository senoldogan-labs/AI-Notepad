import { useThree } from "@react-three/fiber";
import { ThreeCanvas } from "@remotion/three";
import { useMemo } from "react";
import { PMREMGenerator, type Texture } from "three";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import { color } from "../brand";

const useRoomEnvironment = (): Texture => {
  const { gl } = useThree();
  // Built synchronously during render so the very first rendered frame already has reflections.
  return useMemo(() => new PMREMGenerator(gl).fromScene(new RoomEnvironment(), 0.04).texture, [gl]);
};

const OrbMesh: React.FC<{ readonly scale: number; readonly spin: number }> = ({ scale, spin }) => {
  const environment = useRoomEnvironment();
  return (
    <mesh scale={scale} rotation={[0.2, spin, 0]}>
      <sphereGeometry args={[1, 128, 128]} />
      <meshPhysicalMaterial
        color={color.orb}
        roughness={0.32}
        metalness={0}
        clearcoat={1}
        clearcoatRoughness={0.06}
        envMap={environment}
        envMapIntensity={0.55}
      />
    </mesh>
  );
};

/**
 * The app's record orb as a real 3D sphere (Three.js through @remotion/three). `scale` and `spin` come from the
 * scene's frame so every rendered frame is deterministic.
 */
export const Orb: React.FC<{ readonly size: number; readonly scale: number; readonly spin: number }> = ({
  size,
  scale,
  spin,
}) => (
  <ThreeCanvas width={size} height={size} camera={{ position: [0, 0, 6], fov: 30 }} gl={{ alpha: true, antialias: true }}>
    <ambientLight intensity={0.12} />
    <directionalLight position={[-3, 4, 5]} intensity={1.25} color="#fff1e6" />
    <directionalLight position={[4, -2, -3]} intensity={0.7} color={color.lavender} />
    <OrbMesh scale={scale} spin={spin} />
  </ThreeCanvas>
);
