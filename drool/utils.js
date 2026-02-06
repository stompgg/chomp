export async function getFS() {
  try {
    return await import("@tauri-apps/plugin-fs");
  } catch (error) {
    // Web fallback implementation
    return {
      readTextFile: async (path) => {
        console.warn("Tauri FS not available in web environment");
        throw new Error("File system API not available in browser");
      },
      // Add other method fallbacks as needed
      writeTextFile: async (path, content) => {
        console.warn("Tauri FS not available in web environment");
        throw new Error("File system API not available in browser");
      },
    };
  }
}

// Function to load full monster data from CSV
export async function loadFullMonsFromCsv() {
  try {
    const response = await fetch("mons.csv");
    if (response.ok) {
      const csvContent = await response.text();
      const lines = csvContent.split(/\r\n|\n/);

      if (lines.length < 2) return [];

      // Extract headers
      const headers = lines[0].split(",").map((header) => header.trim());

      // Parse data rows
      let monsData = [];
      for (let i = 1; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line) continue;

        const values = parseCsvLine(line);
        if (values[0]) {
          // If it has a name
          const monData = {};
          headers.forEach((header, index) => {
            // Convert numeric values to numbers
            if (
              [
                "HP",
                "Attack",
                "Defense",
                "SpecialAttack",
                "SpecialDefense",
                "Speed",
              ].includes(header)
            ) {
              monData[header] = parseInt(values[index]) || 0;
            } else {
              monData[header] = values[index] || "";
            }
          });
          monsData.push(monData);
        }
      }
      return monsData;
    }
  } catch (error) {
    console.error("Error loading mons.csv:", error);
  }
  return [];
}

export async function loadMovesFromCsv() {
  try {
    const response = await fetch("moves.csv");
    if (response.ok) {
      const csvContent = await response.text();
      const lines = csvContent.split(/\r\n|\n/);

      if (lines.length < 2) return [];

      // Extract headers
      const headers = lines[0].split(",").map((header) => header.trim());

      // Parse data rows
      let movesFromCsv = [];
      for (let i = 1; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line) continue;
        const values = parseCsvLine(line);
        if (values[0]) {
          // If it has a name
          const moveData = {};
          headers.forEach((header, index) => {
            // Convert numeric values to numbers
            if (["Power", "Stamina", "Accuracy"].includes(header)) {
              moveData[header] = values[index] === "?" ? values[index] : parseInt(values[index]) || 0;
            } else {
              moveData[header] = values[index] || "";
            }
          });
          movesFromCsv.push(moveData);
        }
      }
      return movesFromCsv;
    }
  } catch (error) {
    console.error("Error loading moves.csv:", error);
  }
  return [];
}

export async function loadAbilitiesFromCsv() {
  try {
    const response = await fetch("abilities.csv");
    if (response.ok) {
      const csvContent = await response.text();
      const lines = csvContent.split(/\r\n|\n/);

      if (lines.length < 2) return [];

      // Extract headers
      const headers = lines[0].split(",").map((header) => header.trim());
      const abilitiesFromCsv = [];

      for (let i = 1; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line) continue;
        const values = parseCsvLine(line);
        if (values[0]) {
          const abilityData = {};
          headers.forEach((header, index) => {
            abilityData[header] = values[index] || "";
          });
          abilitiesFromCsv.push(abilityData);
        }
      }
      return abilitiesFromCsv;
    }
  } catch (error) {
    console.error("Error loading abilities.csv:", error);
  }
  return [];
} 

function parseCsvLine(line) {
  const result = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];

    if (char === '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] === '"') {
        // Double quotes inside quotes - add a single quote
        current += '"';
        i++;
      } else {
        // Toggle quote mode
        inQuotes = !inQuotes;
      }
    } else if (char === "," && !inQuotes) {
      // End of field
      result.push(current);
      current = "";
    } else {
      current += char;
    }
  }

  // Add the last field
  result.push(current);
  return result;
}

export async function loadTypeData() {
  try {
    const response = await fetch('types.csv');
    if (response.ok) {
      const csvContent = await response.text();
      const lines = csvContent.split(/\r\n|\n/);
      if (lines.length < 2) return [];
      const typeData = {};
      for (let i = 1; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line) continue;
        const values = parseCsvLine(line);
        const typeValue = typeData[values[0]];
        if (!typeValue) {
          typeData[values[0]] = {};
        }
        typeData[values[0]][values[1]] = values[2];
      }
      return typeData;
    }
  }
  catch (error) {
    console.error("Error loading types.csv:", error);
  }
  return {};
}