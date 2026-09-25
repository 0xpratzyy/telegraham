import React from "react";

// Port of DashboardPigeonFlock.swift: the five chonky pigeons with
// sunglasses perched on the squiggle under the Home greeting. Geometry is
// the 100-unit viewBox from the Swift Canvas code.
const STROKE = "rgba(255,255,255,0.7)";
const PROFILES = [
  { size: 56, left: 0.64 },
  { size: 50, left: 0.72 },
  { size: 60, left: 0.8 },
  { size: 52, left: 0.88 },
  { size: 56, left: 0.95 },
];

const Pigeon: React.FC<{ size: number; flap: number; dip: number }> = ({ size, flap, dip }) => {
  const rl = -10 + flap * 60;
  const rr = 10 - flap * 60;
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
      <g stroke={STROKE} strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path strokeWidth={1.6} d="M40 84v6M36 93l4-3M40 90v4M40 90l4 3M60 84v6M56 93l4-3M60 90v4M60 90l4 3" />
        <g transform={`rotate(${rl} 30 60)`}>
          <path strokeWidth={1.6} fill="rgba(255,255,255,0.04)" d="M24 46Q18 50 17 60Q19 72 28 76Q32 70 33 60Q32 50 24 46Z" />
          <path strokeWidth={1.1} d="M20 58Q24 60 28 58M19 64Q24 66 29 64M20 70Q24 72 29 70M22 75Q25 76.5 28 75" />
        </g>
        <g transform={`rotate(${rr} 70 60)`}>
          <path strokeWidth={1.6} fill="rgba(255,255,255,0.04)" d="M76 46Q82 50 83 60Q81 72 72 76Q68 70 67 60Q68 50 76 46Z" />
          <path strokeWidth={1.1} d="M80 58Q76 60 72 58M81 64Q76 66 71 64M80 70Q76 72 71 70M78 75Q75 76.5 72 75" />
        </g>
        <g transform={`translate(0 ${dip}) rotate(${dip * 1.5} 50 50)`}>
          <path strokeWidth={1.6} fill="rgba(255,255,255,0.05)" d="M50 18C30 18 20 34 22 54C24 70 34 84 50 84C66 84 76 70 78 54C80 34 70 18 50 18Z" />
          <path strokeWidth={1.1} stroke="rgba(255,255,255,0.34)" d="M28 44Q50 40 72 44" />
          <path
            strokeWidth={1.1}
            d="M34 56Q38 60 42 56Q46 60 50 56Q54 60 58 56Q62 60 66 56M32 64Q36 68 40 64Q44 68 48 64Q52 68 56 64Q60 68 64 64Q67 67 68 64M34 72Q38 76 42 72Q46 76 50 72Q54 76 58 72Q62 76 66 72"
          />
          <path strokeWidth={1.6} fill="rgba(255,255,255,0.08)" d="M46 42L50 48L54 42Z" />
          <rect x="28" y="30" width="16" height="12" rx="4" fill="#1a1a1a" strokeWidth={1.6} />
          <rect x="56" y="30" width="16" height="12" rx="4" fill="#1a1a1a" strokeWidth={1.6} />
          <path strokeWidth={1.6} d="M44 35h12" />
          <path strokeWidth={1.4} stroke="rgba(255,255,255,0.55)" d="M32 33h3M60 33h3" />
        </g>
      </g>
    </svg>
  );
};

const squigglePath = (w: number) => {
  let d = "M0 4";
  for (let i = 0; i < 80; i++) {
    const xc = ((i * 12.5 + 6.25) / 1000) * w;
    const xe = (((i + 1) * 12.5) / 1000) * w;
    d += ` Q${xc.toFixed(2)} ${i % 2 === 0 ? 0 : 8} ${xe.toFixed(2)} 4`;
  }
  return d;
};

export const PigeonFlock: React.FC<{ width: number; t: number; arrive?: number }> = ({ width, t, arrive = 1 }) => (
  <div style={{ position: "relative", width, height: 8 }}>
    <svg width={width} height={8} style={{ position: "absolute", left: 0, top: 0, overflow: "visible" }}>
      <path d={squigglePath(width)} fill="none" stroke="rgba(255,255,255,0.26)" strokeWidth={1.3} />
    </svg>
    {PROFILES.map((p, i) => {
      const phase = t * 0.07 + i * 1.3;
      const bob = Math.sin(phase) * 1.2;
      const flap = Math.max(0, Math.sin(t * 0.09 + i * 2.1)) > 0.93 ? Math.sin(t * 0.9) * 0.5 : 0;
      const dip = Math.max(0, Math.sin(t * 0.045 + i * 2.7)) ** 8 * 4;
      const drop = (1 - Math.min(1, Math.max(0, arrive * 1.6 - i * 0.12))) * -40;
      return (
        <div
          key={i}
          style={{
            position: "absolute",
            left: p.left * width - p.size / 2,
            bottom: -1 + bob - drop,
            opacity: Math.min(1, Math.max(0, arrive * 1.6 - i * 0.12)),
          }}
        >
          <Pigeon size={p.size} flap={flap} dip={dip} />
        </div>
      );
    })}
  </div>
);
