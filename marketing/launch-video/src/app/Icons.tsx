import React from "react";

// Outline stand-ins for the SF Symbols the app uses.
type P = { size?: number; color?: string; sw?: number };
const S: React.FC<P & { children: React.ReactNode }> = ({ size = 16, color = "currentColor", sw = 1.6, children }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round">
    {children}
  </svg>
);

export const IHome: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M3.5 11 12 4l8.5 7" />
    <path d="M5.5 9.5V20h4.5v-5.5h4V20h4.5V9.5" />
  </S>
);
export const ITray: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M3.5 13.5 6 6h12l2.5 7.5V19h-17z" />
    <path d="M3.5 13.5h5l1.2 2.3h4.6l1.2-2.3h5" />
  </S>
);
export const ICheck: React.FC<P> = (p) => (
  <S {...p}>
    <rect x="4" y="4" width="16" height="16" rx="3" />
    <path d="m8.5 12.3 2.4 2.4 4.8-5" />
  </S>
);
export const IPeople: React.FC<P> = (p) => (
  <S {...p}>
    <circle cx="9" cy="8.5" r="3.2" />
    <path d="M3 19c.6-3.3 3-5 6-5s5.4 1.7 6 5" />
    <circle cx="16.5" cy="9" r="2.6" />
    <path d="M16 14.2c2.6.1 4.4 1.7 5 4.6" />
  </S>
);
export const ISearch: React.FC<P> = (p) => (
  <S {...p}>
    <circle cx="10.5" cy="10.5" r="6.2" />
    <path d="m15.3 15.3 4.7 4.7" />
  </S>
);
export const IRefresh: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3" />
    <path d="M19.5 4.5v4.2h-4.2" />
  </S>
);
export const ISidebar: React.FC<P> = (p) => (
  <S {...p}>
    <rect x="3.5" y="5" width="17" height="14" rx="2.5" />
    <path d="M9 5v14" />
  </S>
);
export const IChevronDown: React.FC<P> = (p) => (
  <S {...p}>
    <path d="m6 9.5 6 6 6-6" />
  </S>
);
export const ISparkle: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M12 3.5c.5 4.3 2.2 6 6.5 6.5-4.3.5-6 2.2-6.5 6.5-.5-4.3-2.2-6-6.5-6.5 4.3-.5 6-2.2 6.5-6.5Z" />
    <path d="M18.5 15.5c.2 1.6.9 2.3 2.5 2.5-1.6.2-2.3.9-2.5 2.5-.2-1.6-.9-2.3-2.5-2.5 1.6-.2 2.3-.9 2.5-2.5Z" />
  </S>
);
export const IBubble: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M4 5.5h16v10H9.5L5.5 19v-3.5H4z" />
    <path d="M8 9.5h8M8 12.5h5" />
  </S>
);
export const IClose: React.FC<P> = (p) => (
  <S {...p}>
    <path d="m6 6 12 12M18 6 6 18" />
  </S>
);
export const IArrowUp: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M12 19V5M6 11l6-6 6 6" />
  </S>
);
export const IArrowDown: React.FC<P> = (p) => (
  <S {...p}>
    <path d="M12 5v14M6 13l6 6 6-6" />
  </S>
);
export const IGrid: React.FC<P> = (p) => (
  <S {...p}>
    <rect x="4" y="4" width="7" height="7" rx="1.5" />
    <rect x="13" y="4" width="7" height="7" rx="1.5" />
    <rect x="4" y="13" width="7" height="7" rx="1.5" />
    <rect x="13" y="13" width="7" height="7" rx="1.5" />
  </S>
);
export const IPlane: React.FC<P> = ({ size = 14, color = "currentColor" }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
    <path d="M21.5 3.2 2.9 10.4c-1 .4-1 1.6.1 1.9l4.6 1.4 1.8 5.6c.3.9 1.4 1.1 2 .4l2.6-2.7 4.7 3.5c.7.5 1.7.1 1.9-.8L23 4.6c.2-1-.6-1.8-1.5-1.4ZM9.6 13.9l8.6-6.4-7 7.4-.4 3.3-1.2-4.3Z" />
  </svg>
);
