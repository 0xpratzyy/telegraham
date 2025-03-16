export type StyleOptions = {
  primaryColor: string;
  secondaryColor: string;
  cornerRadius: string;
  fontFamily: string;
  shadowIntensity: string;
};

// Default style options that can be used as fallback
export const defaultStyleOptions: StyleOptions = {
  primaryColor: "#3B82F6",
  secondaryColor: "#10B981",
  cornerRadius: "8px",
  fontFamily: "inter",
  shadowIntensity: "medium",
};
