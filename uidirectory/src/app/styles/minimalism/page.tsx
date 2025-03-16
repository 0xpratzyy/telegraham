"use client";

import { useState, useEffect } from "react";

// Define type for style options
type StyleOptions = {
  accentColor: string;
  backgroundColor: string;
  textColor: string;
  cornerRadius: string;
  fontFamily: string;
  shadowIntensity: string;
  spacing: string;
  typographyScale: string;
  contrast: string;
};

// Define minimalism-specific default style options
const minimalistStyleOptions: StyleOptions = {
  accentColor: "#000000",
  backgroundColor: "#F5F5F5",
  textColor: "#202020",
  cornerRadius: "2px",
  fontFamily: "inter",
  shadowIntensity: "none",
  spacing: "comfortable",
  typographyScale: "medium",
  contrast: "subtle",
};

export default function MinimalismPage() {
  const [mounted, setMounted] = useState(false);

  // Style customization state
  const [accentColor, setAccentColor] = useState(
    minimalistStyleOptions.accentColor
  );
  const [backgroundColor, setBackgroundColor] = useState(
    minimalistStyleOptions.backgroundColor
  );
  const [textColor, setTextColor] = useState(minimalistStyleOptions.textColor);
  const [cornerRadius, setCornerRadius] = useState(
    minimalistStyleOptions.cornerRadius
  );
  const [fontFamily, setFontFamily] = useState(
    minimalistStyleOptions.fontFamily
  );
  const [shadowIntensity, setShadowIntensity] = useState(
    minimalistStyleOptions.shadowIntensity
  );
  const [spacing, setSpacing] = useState(minimalistStyleOptions.spacing);
  const [typographyScale, setTypographyScale] = useState(
    minimalistStyleOptions.typographyScale
  );
  const [contrast, setContrast] = useState(minimalistStyleOptions.contrast);

  // Toggle state for UI component examples
  const [isToggled, setIsToggled] = useState(false);
  const [tabActive, setTabActive] = useState(0);
  const [selectedValue, setSelectedValue] = useState("option1");
  const [alertVisible, setAlertVisible] = useState(false);

  // Constants for customization options
  const colorOptions = [
    // Light colors
    "#FFFFFF", // White
    "#F8F9FA", // Off-white
    "#F5F5F5", // Light gray
    "#EBEBEB", // Lighter gray
    "#E0E0E0", // Very light gray

    // Dark colors
    "#000000", // Black
    "#202020", // Nearly black
    "#404040", // Dark gray
    "#606060", // Medium gray
    "#808080", // Gray

    // Accent colors
    "#3B82F6", // Blue
    "#10B981", // Green
    "#F59E0B", // Amber
    "#EF4444", // Red
  ];

  const radiusOptions = ["0px", "2px", "4px", "8px", "12px", "16px", "full"];

  const fontOptions = [
    { name: "Inter", value: "inter" },
    { name: "Roboto", value: "roboto" },
    { name: "Helvetica", value: "helvetica" },
    { name: "Montserrat", value: "montserrat" },
    { name: "Open Sans", value: "opensans" },
    { name: "Space Grotesk", value: "spacegrotesk" },
  ];

  const shadowOptions = ["none", "subtle", "light", "medium"];

  const spacingOptions = ["compact", "comfortable", "spacious"];

  const typographyScaleOptions = ["small", "medium", "large"];

  const contrastOptions = ["subtle", "moderate", "high"];

  // Set mounted state after component is mounted
  useEffect(() => {
    setMounted(true);
  }, []);

  // Update styleOptions when individual properties change
  useEffect(() => {
    setAccentColor(accentColor);
    setBackgroundColor(backgroundColor);
    setTextColor(textColor);
    setCornerRadius(cornerRadius);
    setFontFamily(fontFamily);
    setShadowIntensity(shadowIntensity);
    setSpacing(spacing);
    setTypographyScale(typographyScale);
    setContrast(contrast);
  }, [
    accentColor,
    backgroundColor,
    textColor,
    cornerRadius,
    fontFamily,
    shadowIntensity,
    spacing,
    typographyScale,
    contrast,
  ]);

  // Handle custom color change
  const handleAccentColorChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setAccentColor(e.target.value);
  };

  const handleBackgroundColorChange = (
    e: React.ChangeEvent<HTMLInputElement>
  ) => {
    setBackgroundColor(e.target.value);
  };

  const handleTextColorChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setTextColor(e.target.value);
  };

  // Reset to default values
  const handleReset = () => {
    setAccentColor(minimalistStyleOptions.accentColor);
    setBackgroundColor(minimalistStyleOptions.backgroundColor);
    setTextColor(minimalistStyleOptions.textColor);
    setCornerRadius(minimalistStyleOptions.cornerRadius);
    setFontFamily(minimalistStyleOptions.fontFamily);
    setShadowIntensity(minimalistStyleOptions.shadowIntensity);
    setSpacing(minimalistStyleOptions.spacing);
    setTypographyScale(minimalistStyleOptions.typographyScale);
    setContrast(minimalistStyleOptions.contrast);
  };

  // Helper function to get CSS styles based on current settings
  const getComponentStyle = (isAccent = false) => {
    const bgColor = isAccent ? accentColor : backgroundColor;
    let displayTextColor = isAccent
      ? isDarkColor(accentColor)
        ? "#FFFFFF"
        : "#000000"
      : textColor;

    // Apply contrast setting
    if (contrast === "subtle") {
      displayTextColor = isAccent
        ? isDarkColor(accentColor)
          ? "rgba(255,255,255,0.8)"
          : "rgba(0,0,0,0.7)"
        : isDarkColor(backgroundColor)
        ? "rgba(255,255,255,0.8)"
        : "rgba(0,0,0,0.7)";
    } else if (contrast === "moderate") {
      displayTextColor = isAccent
        ? isDarkColor(accentColor)
          ? "rgba(255,255,255,0.9)"
          : "rgba(0,0,0,0.8)"
        : isDarkColor(backgroundColor)
        ? "rgba(255,255,255,0.9)"
        : "rgba(0,0,0,0.8)";
    } else {
      displayTextColor = isAccent
        ? isDarkColor(accentColor)
          ? "#FFFFFF"
          : "#000000"
        : isDarkColor(backgroundColor)
        ? "#FFFFFF"
        : "#000000";
    }

    const style: React.CSSProperties = {
      backgroundColor: bgColor,
      color: displayTextColor,
      borderRadius: cornerRadius === "full" ? "9999px" : cornerRadius,
    };

    // Apply spacing
    if (spacing === "compact") {
      style.padding = "0.5rem";
    } else if (spacing === "comfortable") {
      style.padding = "1rem";
    } else if (spacing === "spacious") {
      style.padding = "1.5rem";
    }

    // Add shadow if needed
    if (shadowIntensity === "subtle") {
      style.boxShadow = "0 1px 2px rgba(0,0,0,0.05)";
    } else if (shadowIntensity === "light") {
      style.boxShadow = "0 2px 4px rgba(0,0,0,0.1)";
    } else if (shadowIntensity === "medium") {
      style.boxShadow = "0 4px 6px rgba(0,0,0,0.1)";
    }

    return style;
  };

  // Function to get border style based on style type
  const getBorderStyle = (): React.CSSProperties => {
    // For minimalism, use subtle borders
    return {
      border: "1px solid",
      borderColor:
        contrast === "subtle"
          ? "rgba(0,0,0,0.05)"
          : contrast === "moderate"
          ? "rgba(0,0,0,0.1)"
          : "rgba(0,0,0,0.15)",
    };
  };

  // Get typography scale for style
  const getTypographyScale = (baseSize: number): number => {
    switch (typographyScale) {
      case "small":
        return baseSize * 0.875;
      case "medium":
        return baseSize;
      case "large":
        return baseSize * 1.125;
      default:
        return baseSize;
    }
  };

  // Helper function to determine if a color is dark (to set appropriate text color)
  const isDarkColor = (color: string): boolean => {
    // Remove the hash (#) if it exists
    const hex = color.replace("#", "");

    // Convert to RGB
    const r = parseInt(hex.substr(0, 2), 16);
    const g = parseInt(hex.substr(2, 2), 16);
    const b = parseInt(hex.substr(4, 2), 16);

    // Calculate luminance
    const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;

    // Return true if the color is dark
    return luminance < 0.5;
  };

  // If not mounted yet, don't render the customization options
  if (!mounted) {
    return (
      <div className="max-w-4xl mx-auto animate-pulse">
        <div className="h-8 bg-neutral-200 rounded w-1/4 mb-2"></div>
        <div className="h-4 bg-neutral-200 rounded w-3/4 mb-8"></div>
        <div className="h-48 bg-neutral-200 rounded mb-4"></div>
        <div className="h-64 bg-neutral-200 rounded"></div>
      </div>
    );
  }

  // Get font family for style
  const getFontFamily = (): string => {
    switch (fontFamily) {
      case "inter":
        return "'Inter', sans-serif";
      case "roboto":
        return "'Roboto', sans-serif";
      case "playfair":
        return "'Playfair Display', serif";
      case "montserrat":
        return "'Montserrat', sans-serif";
      case "opensans":
        return "'Open Sans', sans-serif";
      case "spacegrotesk":
        return "'Space Grotesk', sans-serif";
      default:
        return "'Inter', sans-serif";
    }
  };

  // Style Preview component
  const StylePreview = () => {
    const baseStyle = {
      fontFamily: getFontFamily(),
      fontSize: `${getTypographyScale(16)}px`,
    };

    return (
      <div className="space-y-12 relative" style={baseStyle}>
        {/* Buttons */}
        <section>
          <h2
            className="text-xl font-semibold mb-4"
            style={{ fontSize: `${getTypographyScale(20)}px` }}
          >
            Buttons
          </h2>
          <div className="flex flex-wrap gap-4">
            <button
              className="px-6 py-3 font-medium transition-all"
              style={{
                ...getComponentStyle(true),
                ...getBorderStyle(),
              }}
            >
              Accent Button
            </button>
            <button
              className="px-6 py-3 font-medium transition-all"
              style={{
                ...getComponentStyle(),
                ...getBorderStyle(),
              }}
            >
              Secondary Button
            </button>
          </div>
        </section>

        {/* Input Fields */}
        <section>
          <h2
            className="text-xl font-semibold mb-4"
            style={{ fontSize: `${getTypographyScale(20)}px` }}
          >
            Input Fields
          </h2>
          <div className="space-y-4">
            <div>
              <label className="block font-medium mb-2">Email</label>
              <input
                type="email"
                className="w-full focus:outline-none"
                style={{
                  ...getComponentStyle(),
                  ...getBorderStyle(),
                  padding:
                    spacing === "compact"
                      ? "0.5rem"
                      : spacing === "comfortable"
                      ? "0.75rem"
                      : "1rem",
                }}
                placeholder="your@email.com"
              />
            </div>
            <div>
              <label className="block font-medium mb-2">Password</label>
              <input
                type="password"
                className="w-full focus:outline-none"
                style={{
                  ...getComponentStyle(),
                  ...getBorderStyle(),
                  padding:
                    spacing === "compact"
                      ? "0.5rem"
                      : spacing === "comfortable"
                      ? "0.75rem"
                      : "1rem",
                }}
                placeholder="••••••••"
              />
            </div>
          </div>
        </section>

        {/* Cards */}
        <section>
          <h2
            className="text-xl font-semibold mb-4"
            style={{ fontSize: `${getTypographyScale(20)}px` }}
          >
            Cards
          </h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-6">
            <div
              style={{
                ...getComponentStyle(),
                ...getBorderStyle(),
              }}
            >
              <h3
                className="text-lg font-medium mb-2"
                style={{ fontSize: `${getTypographyScale(18)}px` }}
              >
                Card Title
              </h3>
              <p>
                This is a minimalist card with customized colors and properties.
              </p>
              <button
                className="mt-4 px-4 py-2 font-medium transition-all"
                style={{
                  ...getComponentStyle(true),
                  ...getBorderStyle(),
                  padding:
                    spacing === "compact"
                      ? "0.3rem 0.6rem"
                      : spacing === "comfortable"
                      ? "0.5rem 1rem"
                      : "0.7rem 1.4rem",
                }}
              >
                View Details
              </button>
            </div>
            <div
              style={{
                ...getComponentStyle(true),
                ...getBorderStyle(),
              }}
            >
              <h3
                className="text-lg font-medium mb-2"
                style={{ fontSize: `${getTypographyScale(18)}px` }}
              >
                Card Title
              </h3>
              <p>
                This is a minimalist card with customized colors and properties.
              </p>
              <button
                className="mt-4 px-4 py-2 font-medium transition-all"
                style={{
                  ...getComponentStyle(),
                  ...getBorderStyle(),
                  padding:
                    spacing === "compact"
                      ? "0.3rem 0.6rem"
                      : spacing === "comfortable"
                      ? "0.5rem 1rem"
                      : "0.7rem 1.4rem",
                }}
              >
                View Details
              </button>
            </div>
          </div>
        </section>
      </div>
    );
  };

  return (
    <div className="flex flex-col md:flex-row min-h-screen w-full">
      {/* Main content area */}
      <div className="flex-1 p-4 overflow-y-auto">
        <h1 className="text-3xl font-bold mb-2">Minimalism</h1>
        <p className="text-neutral-600 mb-8">
          Minimalism in UI design emphasizes simplicity, clarity, and
          functionality. It features clean layouts, ample white space,
          thoughtful use of accent colors, and focuses on essential elements to
          create an elegant, uncluttered experience. This approach follows the
          principle of &ldquo;less is more.&rdquo;
        </p>

        <StylePreview />

        {/* Additional UI Components */}
        <div
          className="mt-12 space-y-12"
          style={{
            fontFamily: getFontFamily(),
            fontSize: `${getTypographyScale(16)}px`,
          }}
        >
          <h2
            className="text-2xl font-medium mb-8"
            style={{ fontSize: `${getTypographyScale(24)}px` }}
          >
            More UI Components
          </h2>

          {/* Toggle/Switch */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Toggle/Switch
            </h3>
            <div className="flex items-center space-x-4">
              <button
                onClick={() => setIsToggled(!isToggled)}
                className="relative inline-flex h-6 w-11 items-center rounded-full transition-colors duration-200 ease-in-out focus:outline-none"
                style={{
                  backgroundColor: isToggled ? accentColor : backgroundColor,
                  borderRadius: cornerRadius === "0px" ? "999px" : cornerRadius,
                  opacity: isToggled ? 1 : 0.5,
                }}
              >
                <span
                  className={`inline-block h-4 w-4 transform rounded-full bg-white transition ${
                    isToggled ? "translate-x-6" : "translate-x-1"
                  }`}
                  style={{
                    borderRadius:
                      cornerRadius === "0px" ? "999px" : cornerRadius,
                  }}
                />
              </button>
              <span>{isToggled ? "On" : "Off"}</span>
            </div>
          </section>

          {/* Tabs */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Tabs
            </h3>
            <div className="border-b border-neutral-200">
              <div
                className="flex -mb-px"
                style={{ borderRadius: cornerRadius }}
              >
                {["Tab 1", "Tab 2", "Tab 3"].map((tab, index) => (
                  <button
                    key={index}
                    className="py-2 px-4 font-medium transition-colors duration-150"
                    style={{
                      borderBottom:
                        tabActive === index
                          ? `2px solid ${accentColor}`
                          : "none",
                      color: tabActive === index ? accentColor : "inherit",
                      padding:
                        spacing === "compact"
                          ? "0.5rem 1rem"
                          : spacing === "comfortable"
                          ? "0.75rem 1.5rem"
                          : "1rem 2rem",
                    }}
                    onClick={() => setTabActive(index)}
                  >
                    {tab}
                  </button>
                ))}
              </div>
            </div>
            <div className="py-4">
              <p>{`Content for Tab ${tabActive + 1}`}</p>
            </div>
          </section>

          {/* Badges/Tags */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Badges
            </h3>
            <div className="flex flex-wrap gap-2">
              <span
                className="inline-block py-1 px-3 text-xs font-medium"
                style={{
                  ...getComponentStyle(),
                  padding:
                    spacing === "compact"
                      ? "0.25rem 0.5rem"
                      : spacing === "comfortable"
                      ? "0.35rem 0.7rem"
                      : "0.5rem 1rem",
                }}
              >
                New
              </span>
              <span
                className="inline-block py-1 px-3 text-xs font-medium"
                style={{
                  ...getComponentStyle(true),
                  padding:
                    spacing === "compact"
                      ? "0.25rem 0.5rem"
                      : spacing === "comfortable"
                      ? "0.35rem 0.7rem"
                      : "0.5rem 1rem",
                }}
              >
                Popular
              </span>
              <span
                className="inline-block py-1 px-3 text-xs font-medium border border-current"
                style={{
                  color: accentColor,
                  borderRadius:
                    cornerRadius === "full" ? "9999px" : cornerRadius,
                  padding:
                    spacing === "compact"
                      ? "0.25rem 0.5rem"
                      : spacing === "comfortable"
                      ? "0.35rem 0.7rem"
                      : "0.5rem 1rem",
                }}
              >
                Featured
              </span>
            </div>
          </section>

          {/* Radio Buttons */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Radio Buttons
            </h3>
            <div className="space-y-2">
              {["option1", "option2", "option3"].map((option) => (
                <label
                  key={option}
                  className="flex items-center space-x-2 cursor-pointer"
                >
                  <div
                    className="w-4 h-4 rounded-full border flex items-center justify-center"
                    style={{
                      borderColor: accentColor,
                      borderRadius: "9999px",
                    }}
                  >
                    {selectedValue === option && (
                      <div
                        className="w-2 h-2 rounded-full"
                        style={{
                          backgroundColor: accentColor,
                          borderRadius: "9999px",
                        }}
                      ></div>
                    )}
                  </div>
                  <span onClick={() => setSelectedValue(option)}>
                    {option === "option1"
                      ? "Option 1"
                      : option === "option2"
                      ? "Option 2"
                      : "Option 3"}
                  </span>
                </label>
              ))}
            </div>
          </section>

          {/* Alert/Notification */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Alert
            </h3>
            <button
              className="px-4 py-2 mb-4 font-medium"
              style={{
                ...getComponentStyle(),
                padding:
                  spacing === "compact"
                    ? "0.5rem 1rem"
                    : spacing === "comfortable"
                    ? "0.75rem 1.5rem"
                    : "1rem 2rem",
              }}
              onClick={() => setAlertVisible(true)}
            >
              Show Alert
            </button>

            {alertVisible && (
              <div
                className="relative mb-4 border"
                style={{
                  borderRadius: cornerRadius === "full" ? "8px" : cornerRadius,
                  borderLeftWidth: "4px",
                  borderLeftColor: accentColor,
                  backgroundColor: backgroundColor,
                  padding:
                    spacing === "compact"
                      ? "0.75rem"
                      : spacing === "comfortable"
                      ? "1rem"
                      : "1.5rem",
                }}
              >
                <div className="flex justify-between items-start">
                  <div>
                    <h4
                      className="font-medium"
                      style={{ fontSize: `${getTypographyScale(16)}px` }}
                    >
                      Notification
                    </h4>
                    <p
                      className="text-sm text-neutral-600"
                      style={{ fontSize: `${getTypographyScale(14)}px` }}
                    >
                      This is a minimalist alert notification.
                    </p>
                  </div>
                  <button
                    className="text-neutral-500 hover:text-neutral-700"
                    onClick={() => setAlertVisible(false)}
                    style={{
                      padding: "0.25rem",
                      borderRadius: cornerRadius,
                    }}
                  >
                    ✕
                  </button>
                </div>
              </div>
            )}
          </section>

          {/* Progress Bar */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Progress Bar
            </h3>
            <div
              className="w-full bg-neutral-200 overflow-hidden"
              style={{
                borderRadius: cornerRadius === "full" ? "9999px" : cornerRadius,
                height:
                  spacing === "compact"
                    ? "0.375rem"
                    : spacing === "comfortable"
                    ? "0.5rem"
                    : "0.625rem",
              }}
            >
              <div
                className="h-full transition-all duration-300"
                style={{
                  width: "65%",
                  backgroundColor: accentColor,
                  borderRadius:
                    cornerRadius === "full" ? "9999px" : cornerRadius,
                }}
              ></div>
            </div>
            <div
              className="mt-1 text-sm text-neutral-600"
              style={{ fontSize: `${getTypographyScale(14)}px` }}
            >
              65% Complete
            </div>
          </section>

          {/* Dropdown/Select */}
          <section className="space-y-3">
            <h3
              className="text-xl font-medium mb-4"
              style={{ fontSize: `${getTypographyScale(20)}px` }}
            >
              Dropdown
            </h3>
            <div className="relative w-full max-w-xs">
              <select
                className="w-full appearance-none bg-white border focus:outline-none"
                style={{
                  borderRadius: cornerRadius === "full" ? "8px" : cornerRadius,
                  borderColor: "rgba(0,0,0,0.1)",
                  padding:
                    spacing === "compact"
                      ? "0.5rem"
                      : spacing === "comfortable"
                      ? "0.75rem"
                      : "1rem",
                  fontSize: `${getTypographyScale(16)}px`,
                  backgroundColor: backgroundColor,
                  color: isDarkColor(backgroundColor) ? "#FFFFFF" : "#000000",
                }}
              >
                <option>Select an option</option>
                <option>Option 1</option>
                <option>Option 2</option>
                <option>Option 3</option>
              </select>
              <div className="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2 text-neutral-700">
                <svg
                  className="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke={isDarkColor(backgroundColor) ? "#FFFFFF" : "#000000"}
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </div>
            </div>
          </section>
        </div>
      </div>

      {/* Sidebar - Customize Box */}
      <div className="md:w-80 shrink-0 h-screen bg-white border-l border-neutral-200 sticky top-0 right-0 overflow-y-auto">
        <div className="h-full flex flex-col">
          <div className="flex justify-between items-center p-4 border-b border-neutral-200">
            <h2 className="text-lg font-semibold">Customize Minimalism</h2>
            <button
              onClick={handleReset}
              className="text-xs px-2 py-1 text-blue-600 hover:bg-blue-50 rounded"
            >
              Reset to Default
            </button>
          </div>

          <div className="p-4 space-y-6 flex-1 overflow-y-auto">
            {/* Colors Section */}
            <div className="space-y-4">
              <h3 className="text-sm font-medium text-neutral-500 uppercase tracking-wider">
                Colors
              </h3>

              {/* Accent Color Picker */}
              <div>
                <h4 className="text-sm font-medium mb-2">Accent Color</h4>
                <div className="flex items-center mb-2">
                  <input
                    type="color"
                    value={accentColor}
                    onChange={handleAccentColorChange}
                    className="w-8 h-8 rounded border border-neutral-200 mr-2"
                    aria-label="Pick accent color"
                  />
                  <span className="text-xs font-mono">{accentColor}</span>
                </div>
                <div className="grid grid-cols-4 gap-2">
                  {colorOptions.map((color) => (
                    <button
                      key={color}
                      className={`w-6 h-6 rounded-full border ${
                        color === accentColor
                          ? "ring-2 ring-offset-2 ring-blue-500"
                          : "border-neutral-200"
                      }`}
                      style={{ backgroundColor: color }}
                      aria-label={`Select color ${color}`}
                      onClick={() => setAccentColor(color)}
                    />
                  ))}
                </div>
              </div>

              {/* Background Color Picker */}
              <div>
                <h4 className="text-sm font-medium mb-2">Background Color</h4>
                <div className="flex items-center mb-2">
                  <input
                    type="color"
                    value={backgroundColor}
                    onChange={handleBackgroundColorChange}
                    className="w-8 h-8 rounded border border-neutral-200 mr-2"
                    aria-label="Pick background color"
                  />
                  <span className="text-xs font-mono">{backgroundColor}</span>
                </div>
                <div className="grid grid-cols-4 gap-2">
                  {colorOptions.map((color) => (
                    <button
                      key={color}
                      className={`w-6 h-6 rounded-full border ${
                        color === backgroundColor
                          ? "ring-2 ring-offset-2 ring-blue-500"
                          : "border-neutral-200"
                      }`}
                      style={{ backgroundColor: color }}
                      aria-label={`Select color ${color}`}
                      onClick={() => setBackgroundColor(color)}
                    />
                  ))}
                </div>
              </div>

              {/* Text Color Picker */}
              <div>
                <h4 className="text-sm font-medium mb-2">Text Color</h4>
                <div className="flex items-center mb-2">
                  <input
                    type="color"
                    value={textColor}
                    onChange={handleTextColorChange}
                    className="w-8 h-8 rounded border border-neutral-200 mr-2"
                    aria-label="Pick text color"
                  />
                  <span className="text-xs font-mono">{textColor}</span>
                </div>
                <div className="grid grid-cols-4 gap-2">
                  {colorOptions.map((color) => (
                    <button
                      key={color}
                      className={`w-6 h-6 rounded-full border ${
                        color === textColor
                          ? "ring-2 ring-offset-2 ring-blue-500"
                          : "border-neutral-200"
                      }`}
                      style={{ backgroundColor: color }}
                      aria-label={`Select color ${color}`}
                      onClick={() => setTextColor(color)}
                    />
                  ))}
                </div>
              </div>

              {/* Contrast */}
              <div>
                <h4 className="text-sm font-medium mb-2">Contrast</h4>
                <div className="grid grid-cols-3 gap-2">
                  {contrastOptions.map((option) => (
                    <button
                      key={option}
                      className={`px-2 py-1 text-xs rounded ${
                        option === contrast
                          ? "bg-blue-100 text-blue-800"
                          : "bg-neutral-100 text-neutral-800"
                      }`}
                      onClick={() => setContrast(option)}
                    >
                      {option}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            {/* Typography Section */}
            <div className="space-y-4">
              <h3 className="text-sm font-medium text-neutral-500 uppercase tracking-wider">
                Typography
              </h3>

              {/* Font Family */}
              <div>
                <h4 className="text-sm font-medium mb-2">Font Family</h4>
                <select
                  value={fontFamily}
                  onChange={(e) => setFontFamily(e.target.value)}
                  className="w-full px-3 py-2 bg-neutral-100 rounded border border-neutral-200"
                >
                  {fontOptions.map((font) => (
                    <option key={font.value} value={font.value}>
                      {font.name}
                    </option>
                  ))}
                </select>
              </div>

              {/* Typography Scale */}
              <div>
                <h4 className="text-sm font-medium mb-2">Typography Scale</h4>
                <div className="grid grid-cols-3 gap-2">
                  {typographyScaleOptions.map((option) => (
                    <button
                      key={option}
                      className={`px-2 py-1 text-xs rounded ${
                        option === typographyScale
                          ? "bg-blue-100 text-blue-800"
                          : "bg-neutral-100 text-neutral-800"
                      }`}
                      onClick={() => setTypographyScale(option)}
                    >
                      {option}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            {/* Layout Section */}
            <div className="space-y-4">
              <h3 className="text-sm font-medium text-neutral-500 uppercase tracking-wider">
                Layout
              </h3>

              {/* Corner Radius */}
              <div>
                <h4 className="text-sm font-medium mb-2">Corner Radius</h4>
                <div className="grid grid-cols-4 gap-2">
                  {radiusOptions.map((radius) => (
                    <button
                      key={radius}
                      className={`px-2 py-1 text-xs rounded ${
                        radius === cornerRadius
                          ? "bg-blue-100 text-blue-800"
                          : "bg-neutral-100 text-neutral-800"
                      }`}
                      onClick={() => setCornerRadius(radius)}
                    >
                      {radius}
                    </button>
                  ))}
                </div>
              </div>

              {/* Spacing */}
              <div>
                <h4 className="text-sm font-medium mb-2">Spacing</h4>
                <div className="grid grid-cols-3 gap-2">
                  {spacingOptions.map((option) => (
                    <button
                      key={option}
                      className={`px-2 py-1 text-xs rounded ${
                        option === spacing
                          ? "bg-blue-100 text-blue-800"
                          : "bg-neutral-100 text-neutral-800"
                      }`}
                      onClick={() => setSpacing(option)}
                    >
                      {option}
                    </button>
                  ))}
                </div>
              </div>

              {/* Shadow Intensity */}
              <div>
                <h4 className="text-sm font-medium mb-2">Shadow Intensity</h4>
                <div className="grid grid-cols-2 gap-2">
                  {shadowOptions.map((shadow) => (
                    <button
                      key={shadow}
                      className={`px-2 py-1 text-xs rounded ${
                        shadow === shadowIntensity
                          ? "bg-blue-100 text-blue-800"
                          : "bg-neutral-100 text-neutral-800"
                      }`}
                      onClick={() => setShadowIntensity(shadow)}
                    >
                      {shadow}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
