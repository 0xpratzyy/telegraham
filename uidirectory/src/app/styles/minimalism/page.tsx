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

  // State for generated prompt
  const [generatedPrompt, setGeneratedPrompt] = useState("");
  const [showPrompt, setShowPrompt] = useState(false);

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

  // Generate a prompt based on current style selections
  const generateStylePrompt = () => {
    const fontNames = {
      inter: "Inter",
      roboto: "Roboto",
      helvetica: "Helvetica",
      montserrat: "Montserrat",
      opensans: "Open Sans",
      spacegrotesk: "Space Grotesk",
    };

    const prompt = `Create a minimalist UI design with these exact specifications:

STYLE: Minimalist
COLOR PALETTE:
- Primary/Accent: ${accentColor} (for buttons, highlights, interactive elements)
- Background: ${backgroundColor} (main surface color)
- Text: ${textColor} (for typography elements)

VISUAL PROPERTIES:
- Corner Radius: ${cornerRadius} (for buttons, cards, input fields)
- Font Family: ${fontNames[fontFamily as keyof typeof fontNames] || fontFamily}
- Shadow: ${shadowIntensity} (determines depth and elevation)
- Spacing: ${spacing} (controls density and whitespace)
- Typography Scale: ${typographyScale} (text sizing relationship)
- Contrast: ${contrast} (visual distinction between elements)

DESIGN PRINCIPLES:
- Use clean, uncluttered layouts with ample whitespace
- Focus on essential elements only
- Maintain consistency across all components
- Prioritize readability and usability
- Follow "less is more" philosophy`;

    setGeneratedPrompt(prompt);
    setShowPrompt(true);
  };

  return (
    <div className="flex flex-col p-0 md:flex-row min-h-screen w-full">
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
      <div className="md:w-96 shrink-0 h-screen bg-white border-l border-neutral-200 sticky overflow-y-auto">
        <div className="h-full flex flex-col">
          <div className="flex justify-between items-center p-5 border-b border-neutral-200">
            <h2 className="text-xl font-semibold">Customize Style</h2>
            <button
              onClick={handleReset}
              className="text-sm px-3 py-1.5 bg-neutral-100 hover:bg-neutral-200 rounded-md transition-colors"
            >
              Reset to Default
            </button>
          </div>

          <div className="flex-1 overflow-y-auto">
            {/* Color Section */}
            <div className="p-5 border-b border-neutral-200">
              <details open className="group">
                <summary className="flex items-center justify-between cursor-pointer list-none">
                  <h3 className="text-md font-semibold mb-2">Colors</h3>
                  <svg
                    className="w-5 h-5 group-open:rotate-180 transition-transform"
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 20 20"
                    fill="currentColor"
                  >
                    <path
                      fillRule="evenodd"
                      d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
                      clipRule="evenodd"
                    />
                  </svg>
                </summary>
                <div className="pt-4 space-y-6">
                  {/* Accent Color Picker */}
                  <div>
                    <div className="flex items-center justify-between mb-2">
                      <label className="text-sm font-medium">
                        Accent Color
                      </label>
                      <div className="flex items-center">
                        <input
                          type="color"
                          value={accentColor}
                          onChange={handleAccentColorChange}
                          className="w-8 h-8 rounded border border-neutral-200 cursor-pointer"
                          aria-label="Pick accent color"
                        />
                        <span className="ml-2 text-xs font-mono">
                          {accentColor}
                        </span>
                      </div>
                    </div>
                    <div className="grid grid-cols-7 gap-2">
                      {colorOptions.map((color) => (
                        <button
                          key={color}
                          className={`w-9 h-9 rounded-md transition-all hover:scale-110 ${
                            color === accentColor
                              ? "ring-2 ring-offset-2 ring-blue-500 scale-110"
                              : "ring-1 ring-neutral-200"
                          }`}
                          style={{ backgroundColor: color }}
                          aria-label={`Select color ${color}`}
                          onClick={() => setAccentColor(color)}
                          title={color}
                        />
                      ))}
                    </div>
                  </div>

                  {/* Background Color Picker */}
                  <div>
                    <div className="flex items-center justify-between mb-2">
                      <label className="text-sm font-medium">
                        Background Color
                      </label>
                      <div className="flex items-center">
                        <input
                          type="color"
                          value={backgroundColor}
                          onChange={handleBackgroundColorChange}
                          className="w-8 h-8 rounded border border-neutral-200 cursor-pointer"
                          aria-label="Pick background color"
                        />
                        <span className="ml-2 text-xs font-mono">
                          {backgroundColor}
                        </span>
                      </div>
                    </div>
                    <div className="grid grid-cols-7 gap-2">
                      {colorOptions.map((color) => (
                        <button
                          key={color}
                          className={`w-9 h-9 rounded-md transition-all hover:scale-110 ${
                            color === backgroundColor
                              ? "ring-2 ring-offset-2 ring-blue-500 scale-110"
                              : "ring-1 ring-neutral-200"
                          }`}
                          style={{ backgroundColor: color }}
                          aria-label={`Select color ${color}`}
                          onClick={() => setBackgroundColor(color)}
                          title={color}
                        />
                      ))}
                    </div>
                  </div>

                  {/* Text Color Picker */}
                  <div>
                    <div className="flex items-center justify-between mb-2">
                      <label className="text-sm font-medium">Text Color</label>
                      <div className="flex items-center">
                        <input
                          type="color"
                          value={textColor}
                          onChange={handleTextColorChange}
                          className="w-8 h-8 rounded border border-neutral-200 cursor-pointer"
                          aria-label="Pick text color"
                        />
                        <span className="ml-2 text-xs font-mono">
                          {textColor}
                        </span>
                      </div>
                    </div>
                    <div className="grid grid-cols-7 gap-2">
                      {colorOptions.map((color) => (
                        <button
                          key={color}
                          className={`w-9 h-9 rounded-md transition-all hover:scale-110 ${
                            color === textColor
                              ? "ring-2 ring-offset-2 ring-blue-500 scale-110"
                              : "ring-1 ring-neutral-200"
                          }`}
                          style={{ backgroundColor: color }}
                          aria-label={`Select color ${color}`}
                          onClick={() => setTextColor(color)}
                          title={color}
                        />
                      ))}
                    </div>
                  </div>

                  {/* Contrast */}
                  <div>
                    <label className="text-sm font-medium block mb-2">
                      Contrast
                    </label>
                    <div className="grid grid-cols-3 gap-2">
                      {contrastOptions.map((option) => (
                        <button
                          key={option}
                          className={`py-2 px-3 rounded-md transition-colors ${
                            option === contrast
                              ? "bg-blue-500 text-white"
                              : "bg-neutral-100 text-neutral-800 hover:bg-neutral-200"
                          }`}
                          onClick={() => setContrast(option)}
                        >
                          {option}
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
              </details>
            </div>

            {/* Typography Section */}
            <div className="p-5 border-b border-neutral-200">
              <details className="group">
                <summary className="flex items-center justify-between cursor-pointer list-none">
                  <h3 className="text-md font-semibold mb-2">Typography</h3>
                  <svg
                    className="w-5 h-5 group-open:rotate-180 transition-transform"
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 20 20"
                    fill="currentColor"
                  >
                    <path
                      fillRule="evenodd"
                      d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
                      clipRule="evenodd"
                    />
                  </svg>
                </summary>
                <div className="pt-4 space-y-6">
                  {/* Font Family */}
                  <div>
                    <label className="text-sm font-medium block mb-2">
                      Font Family
                    </label>
                    <div className="relative">
                      <select
                        value={fontFamily}
                        onChange={(e) => setFontFamily(e.target.value)}
                        className="w-full px-4 py-2.5 bg-white rounded-md border border-neutral-300 shadow-sm appearance-none cursor-pointer focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                      >
                        {fontOptions.map((font) => (
                          <option
                            key={font.value}
                            value={font.value}
                            style={{ fontFamily: font.name }}
                          >
                            {font.name}
                          </option>
                        ))}
                      </select>
                      <div className="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2">
                        <svg
                          className="w-5 h-5 text-gray-400"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            strokeWidth="2"
                            d="M19 9l-7 7-7-7"
                          ></path>
                        </svg>
                      </div>
                    </div>
                  </div>

                  {/* Font Preview */}
                  <div className="p-4 border border-neutral-200 rounded-md">
                    <p style={{ fontFamily: getFontFamily() }}>
                      Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm Nn Oo Pp Qq Rr Ss
                      Tt Uu Vv Ww Xx Yy Zz
                    </p>
                  </div>

                  {/* Typography Scale */}
                  <div>
                    <label className="text-sm font-medium block mb-2">
                      Typography Scale
                    </label>
                    <div className="grid grid-cols-3 gap-2">
                      {typographyScaleOptions.map((option) => (
                        <button
                          key={option}
                          className={`py-2 px-3 rounded-md transition-colors ${
                            option === typographyScale
                              ? "bg-blue-500 text-white"
                              : "bg-neutral-100 text-neutral-800 hover:bg-neutral-200"
                          }`}
                          onClick={() => setTypographyScale(option)}
                        >
                          <span
                            className={
                              option === "small"
                                ? "text-sm"
                                : option === "large"
                                ? "text-lg"
                                : "text-base"
                            }
                          >
                            {option}
                          </span>
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
              </details>
            </div>

            {/* Layout Section */}
            <div className="p-5 border-b border-neutral-200">
              <details className="group">
                <summary className="flex items-center justify-between cursor-pointer list-none">
                  <h3 className="text-md font-semibold mb-2">
                    Layout & Structure
                  </h3>
                  <svg
                    className="w-5 h-5 group-open:rotate-180 transition-transform"
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 20 20"
                    fill="currentColor"
                  >
                    <path
                      fillRule="evenodd"
                      d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
                      clipRule="evenodd"
                    />
                  </svg>
                </summary>
                <div className="pt-4 space-y-6">
                  {/* Corner Radius - Visual Preview */}
                  <div>
                    <label className="text-sm font-medium block mb-2">
                      Corner Radius
                    </label>
                    <div className="grid grid-cols-4 gap-3 mb-4">
                      {radiusOptions.map((radius) => {
                        const radiusValue =
                          radius === "full" ? "9999px" : radius;
                        return (
                          <button
                            key={radius}
                            className={`rounded-md border transition-all h-14 flex items-center justify-center hover:border-blue-400 ${
                              radius === cornerRadius
                                ? "ring-2 ring-blue-500 border-blue-500"
                                : "border-neutral-300"
                            }`}
                            style={{
                              borderRadius: radiusValue,
                            }}
                            onClick={() => setCornerRadius(radius)}
                            title={radius}
                          >
                            <span className="text-xs font-medium">
                              {radius}
                            </span>
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Spacing */}
                  <div>
                    <label className="text-sm font-medium block mb-2">
                      Spacing
                    </label>
                    <div className="grid grid-cols-3 gap-3">
                      {spacingOptions.map((option) => (
                        <button
                          key={option}
                          className={`py-2 px-3 rounded-md transition-colors flex flex-col items-center ${
                            option === spacing
                              ? "bg-blue-500 text-white"
                              : "bg-neutral-100 text-neutral-800 hover:bg-neutral-200"
                          }`}
                          onClick={() => setSpacing(option)}
                        >
                          <div className="mb-1">
                            {option === "compact" ? (
                              <div className="w-8 h-2 bg-current"></div>
                            ) : option === "comfortable" ? (
                              <div className="w-6 h-2 bg-current"></div>
                            ) : (
                              <div className="w-4 h-2 bg-current"></div>
                            )}
                          </div>
                          <span className="text-xs">{option}</span>
                        </button>
                      ))}
                    </div>
                  </div>

                  {/* Shadow Intensity */}
                  <div>
                    <label className="text-sm font-medium block mb-2">
                      Shadow Intensity
                    </label>
                    <div className="grid grid-cols-2 gap-3">
                      {shadowOptions.map((shadow) => (
                        <button
                          key={shadow}
                          className={`py-3 px-3 border rounded-md transition-all overflow-hidden ${
                            shadow === shadowIntensity
                              ? "ring-2 ring-blue-500 border-blue-500"
                              : "border-neutral-300 hover:border-blue-400"
                          }`}
                          onClick={() => setShadowIntensity(shadow)}
                          style={{
                            boxShadow:
                              shadow === "none"
                                ? "none"
                                : shadow === "subtle"
                                ? "0 1px 2px rgba(0,0,0,0.05)"
                                : shadow === "light"
                                ? "0 2px 4px rgba(0,0,0,0.1)"
                                : "0 4px 6px rgba(0,0,0,0.1)",
                          }}
                        >
                          <div className="flex items-center justify-between">
                            <span className="text-sm">{shadow}</span>
                            <div className="w-4 h-4 bg-neutral-400 rounded"></div>
                          </div>
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
              </details>
            </div>

            {/* Save Presets Section */}
            <div className="p-5">
              <div className="space-y-3">
                <h3 className="text-md font-semibold mb-2">Prompt Generator</h3>
                <button
                  onClick={generateStylePrompt}
                  className="w-full px-4 py-3 bg-blue-500 hover:bg-blue-600 text-white rounded-md transition-colors text-center font-medium flex items-center justify-center gap-2"
                >
                  <svg
                    className="w-5 h-5"
                    viewBox="0 0 24 24"
                    fill="none"
                    xmlns="http://www.w3.org/2000/svg"
                  >
                    <path
                      d="M12 2L20 7V17L12 22L4 17V7L12 2Z"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                    <path
                      d="M12 22V12"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                    <path
                      d="M20 7L12 12L4 7"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                  Generate Style Prompt
                </button>

                {showPrompt && (
                  <div className="mt-4 border border-neutral-200 rounded-md p-4 bg-neutral-50 relative">
                    <button
                      onClick={() => setShowPrompt(false)}
                      className="absolute top-2 right-2 text-neutral-400 hover:text-neutral-600"
                      aria-label="Close prompt"
                    >
                      <svg
                        className="w-4 h-4"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth="2"
                          d="M6 18L18 6M6 6l12 12"
                        ></path>
                      </svg>
                    </button>
                    <h4 className="font-medium mb-2 text-sm">
                      Generated Prompt:
                    </h4>
                    <div className="relative">
                      <pre className="text-xs bg-white p-3 rounded border border-neutral-200 whitespace-pre-wrap">
                        {generatedPrompt}
                      </pre>
                      <button
                        onClick={() => {
                          navigator.clipboard.writeText(generatedPrompt);
                          alert("Copied to clipboard!");
                        }}
                        className="absolute top-2 right-2 text-neutral-400 hover:text-neutral-600 bg-white rounded-md p-1"
                        title="Copy to clipboard"
                      >
                        <svg
                          className="w-4 h-4"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            strokeWidth="2"
                            d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                          ></path>
                        </svg>
                      </button>
                    </div>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
