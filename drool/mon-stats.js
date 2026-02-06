import { typeData } from "./type-data.js";
import { getFS } from "./utils.js";

// Create a global variable to store monster data for other modules to access
window.monsterData = {
  data: [],
  columns: []
};

document.addEventListener("DOMContentLoaded", function () {
  // Init filesystem APIs (if available)
  getFS().then(async (fs) => {
    // Elements
    const dataTable = document.getElementById("data-table");
    const importBtn = document.getElementById("import-btn");
    const fileInput = document.getElementById("file-input");
    const addRowBtn = document.getElementById("add-row-btn");
    const exportBtn = document.getElementById("export-btn");
    const exportJsBtn = document.getElementById("export-js-btn");
    const tabs = document.querySelectorAll(".tab");
    const tabContents = document.querySelectorAll(".tab-content");
    const mobileTabsSelect = document.getElementById("mobile-tabs");

    // Add this near other element declarations
    const saveIndicator = document.createElement("span");
    saveIndicator.id = "save-indicator";
    saveIndicator.textContent = "●";
    saveIndicator.style.color = "#4CAF50";
    saveIndicator.style.marginLeft = "8px";
    saveIndicator.style.opacity = "0";
    saveIndicator.title = "All changes saved";

    // Add the indicator next to export buttons
    exportBtn.parentElement.appendChild(saveIndicator);

    let hasUnsavedChanges = false;

    function markUnsavedChanges() {
      hasUnsavedChanges = true;
      saveIndicator.style.opacity = "1";
      saveIndicator.style.color = "#ff9800";
      saveIndicator.title = "Unsaved changes";
    }

    function markChangesSaved() {
      hasUnsavedChanges = false;
      saveIndicator.style.opacity = "1";
      saveIndicator.style.color = "#4CAF50";
      saveIndicator.title = "All changes saved";
      // Fade out after 2 seconds
      setTimeout(() => {
        saveIndicator.style.opacity = "0";
      }, 2000);
    }

    // Function to notify other components when monster data changes
    function notifyDataUpdated() {
      // Update global variable
      window.monsterData = {
        data: data,
        columns: columns
      };

      // Dispatch custom event
      document.dispatchEvent(
        new CustomEvent("monster-data-updated", {
          detail: {
            data: data,
            columns: columns
          }
        })
      );
    }

    let columns = [];
    let data = [];

    // Try to load from mons.csv first using fetch
    try {
      const response = await fetch('mons.csv');
      if (response.ok) {
        const csvContent = await response.text();
        parseCSV(csvContent);
      } else {
        throw new Error('Failed to fetch CSV');
      }
    } catch (error) {
      console.log("Could not load mons.csv, using default data", error);
      // Still notify with empty data
      notifyDataUpdated();
    }

    // Sort vars
    let columnToSort = undefined;
    let columnDirection = false;

    // Event listeners
    importBtn.addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", handleFileImport);
    addRowBtn.addEventListener("click", addRow);
    exportBtn.addEventListener("click", exportToCsv);
    exportJsBtn.addEventListener("click", exportToJs);

    // Tab navigation
    tabs.forEach((tab) => {
      tab.addEventListener("click", () => {
        const tabId = tab.dataset.tab;
        activateTab(tabId);
        let hashId = tabId;
        // Update URL hash without triggering a page reload
        window.history.pushState(null, null, `#${hashId}`);

        // Update mobile dropdown to match selected tab
        if (mobileTabsSelect) {
          mobileTabsSelect.value = tabId;
        }
      });
    });

    // Mobile tabs dropdown navigation
    if (mobileTabsSelect) {
      mobileTabsSelect.addEventListener("change", () => {
        const tabId = mobileTabsSelect.value;
        activateTab(tabId);

        // Special case for data tab - use #stats in URL
        let hashId = tabId;

        // Update URL hash without triggering a page reload
        window.history.pushState(null, null, `#${hashId}`);
      });
    }

    // Function to activate a specific tab
    function activateTab(tabId) {
      // Remove active class from all tabs and contents
      tabs.forEach((t) => t.classList.remove("active"));
      tabContents.forEach((c) => c.classList.remove("active"));

      // Add active class to selected tab and content
      const selectedTab = document.querySelector(`.tab[data-tab="${tabId}"]`);

      // Handle special case for data tab which now has id="stats"
      let contentId = tabId;

      const selectedContent = document.getElementById(contentId);

      if (selectedTab && selectedContent) {
        selectedTab.classList.add("active");
        selectedContent.classList.add("active");
      }
    }

    // Check URL hash on page load
    function checkUrlHash() {
      const hash = window.location.hash.substring(1); // Remove the # symbol

      // Handle special case for stats hash which should activate data tab
      if (hash === "stats") {
        activateTab("stats");
        // Update mobile dropdown to match
        if (mobileTabsSelect) {
          mobileTabsSelect.value = "stats";
        }
        return;
      }

      // Handle mons with index pattern (e.g., #mons0, #mons1)
      const monsMatch = hash.match(/^mons(\d+)$/);
      if (monsMatch) {
        const monIndex = parseInt(monsMatch[1], 10);
        activateTab("mons");
        // Update mobile dropdown to match
        if (mobileTabsSelect) {
          mobileTabsSelect.value = "mons";
        }
        // Dispatch event to navigate to specific mon
        document.dispatchEvent(new CustomEvent("navigate-to-mon", { detail: { index: monIndex } }));
        return;
      }

      if (hash && document.getElementById(hash)) {
        activateTab(hash);
        // Update mobile dropdown to match
        if (mobileTabsSelect) {
          mobileTabsSelect.value = hash;
        }
      }
    }

    // Listen for hash changes (browser back/forward buttons)
    window.addEventListener("hashchange", checkUrlHash);

    // Initialize tables first, then check hash
    renderDataTable();
    notifyDataUpdated(); // Notify other components about initial data

    // Check hash when page loads (after rendering)
    checkUrlHash();

    // Add event listener for keyboard shortcuts
    document.addEventListener("keydown", function(event) {
      // Check for Ctrl+S (or Cmd+S on Mac)
      if ((event.ctrlKey || event.metaKey) && event.key === 's') {
        event.preventDefault(); // Prevent browser's save dialog

        // Check which tab is active
        const activeTab = document.querySelector(".tab.active");

        if (activeTab && activeTab.dataset.tab === "stats") {
          exportToCsv(); // Save monster data
        }
      }
    });

    // Functions
    function renderDataTable() {
      const tbody = dataTable.querySelector("tbody");
      tbody.innerHTML = "";

      // Update headers first
      updateTableHeaders();

      // Render data rows
      data.forEach((row, rowIndex) => {
        const tr = document.createElement("tr");

        // Add image cell before other columns
        const imgTd = document.createElement("td");
        const img = document.createElement("img");
        const monsterName = (row.Name || "").toLowerCase();
        img.src = `imgs/${monsterName}_mini.gif`;
        img.alt = row.Name || "";
        img.onerror = () => (img.style.display = "none"); // Hide if image not found
        imgTd.appendChild(img);
        tr.appendChild(imgTd);

        columns.forEach((column) => {
          const td = document.createElement("td");

          // Always add data attributes regardless of editability
          td.dataset.row = rowIndex;
          td.dataset.column = column.name;

          if (column.name === "Type1" || column.name === "Type2") {
            // Create type dropdown
            const select = document.createElement("select");
            select.style.width = "100%";
            select.style.padding = "4px";
            select.style.backgroundColor = "transparent";
            select.style.border = "none";
            select.style.cursor = "pointer";
            select.style.color = "inherit";

            // Add empty option
            const emptyOption = document.createElement("option");
            emptyOption.value = "";
            emptyOption.textContent = "Select type...";
            select.appendChild(emptyOption);

            // Add type options
            Object.entries(typeData).forEach(([type, info]) => {
              const option = document.createElement("option");
              option.value = type;
              option.textContent = `${info.emoji} ${type}`;
              option.style.backgroundColor = info.bgColor;
              option.style.color = info.textColor;
              if (type === row[column.name]) {
                option.selected = true;
                td.style.backgroundColor = info.bgColor;
                td.style.color = info.textColor;
                select.style.backgroundColor = info.bgColor;
                select.style.color = info.textColor;
              }
              select.appendChild(option);
            });

            // Handle change event
            select.addEventListener("change", (e) => {
              const selectedType = e.target.value;
              const typeInfo = typeData[selectedType];

              // Update cell styling
              td.style.backgroundColor = selectedType ? typeInfo.bgColor : "";
              td.style.color = selectedType ? typeInfo.textColor : "";
              select.style.backgroundColor = selectedType ? typeInfo.bgColor : "transparent";
              select.style.color = selectedType ? typeInfo.textColor : "inherit";

              // Update data
              data[rowIndex][column.name] = selectedType;
            });

            td.appendChild(select);
          } else if (column.name === "Flavor") {
            // Special handling for Flavor field - make it a textarea for multi-line text
            const textarea = document.createElement("textarea");
            textarea.style.width = "100%";
            textarea.style.minHeight = "60px";
            textarea.style.padding = "4px";
            textarea.style.backgroundColor = "transparent";
            textarea.style.border = "1px solid #444";
            textarea.style.color = "inherit";
            textarea.style.fontFamily = "inherit";
            textarea.style.fontSize = "inherit";
            textarea.style.resize = "vertical";
            textarea.value = row[column.name] || "";

            textarea.addEventListener("blur", (e) => {
              data[rowIndex][column.name] = e.target.value;
              markUnsavedChanges();
              notifyDataUpdated();
            });

            td.appendChild(textarea);
          } else if (column.editable) {
            td.contentEditable = true;
            td.className = "editable";

            if (column.type === "number") {
              td.textContent = row[column.name] || 0;
              td.addEventListener("input", validateNumberInput);
            } else {
              td.textContent = row[column.name] || "";
            }

            td.addEventListener("blur", updateData);
          } else {
            td.textContent = row[column.name] || "";
          }

          tr.appendChild(td);
        });

        // Add action buttons
        const actionsTd = document.createElement("td");
        const deleteBtn = document.createElement("button");
        deleteBtn.textContent = "❌";
        deleteBtn.style.backgroundColor = "#111";
        deleteBtn.addEventListener("click", () => {
          deleteRow(rowIndex);
        });

        actionsTd.appendChild(deleteBtn);
        tr.appendChild(actionsTd);

        tbody.appendChild(tr);
      });

      updateStatsHeatmap();
    }

    function updateTableHeaders() {
      const headerRow = dataTable.querySelector("thead tr");
      headerRow.innerHTML = "";

      // Add image column header
      const imgHeader = document.createElement("th");
      imgHeader.textContent = "Icon";
      headerRow.appendChild(imgHeader);

      columns.forEach((column) => {
        const th = document.createElement("th");
        th.className = "column-header";

        const headerContent = document.createElement("div");
        headerContent.style.display = "flex";
        headerContent.style.alignItems = "center";
        headerContent.style.gap = "5px";

        const headerText = document.createElement("span");
        headerText.textContent = column.name;
        headerContent.appendChild(headerText);

        if (column.type === "number") {
          const sortIndicator = document.createElement("span");
          sortIndicator.className = "sort-indicator";
          sortIndicator.innerHTML = "";

          headerContent.addEventListener("click", () => {
            if (columnToSort === column.name && columnDirection === true) {
              columnToSort = column.name;
              columnDirection = false;
              sortData(columnToSort, false);
            } else {
              columnToSort = column.name;
              columnDirection = true;
              sortData(columnToSort, true);
            }
          });

          headerContent.appendChild(sortIndicator);
        }

        th.appendChild(headerContent);
        headerRow.appendChild(th);
      });

      const actionsHeader = document.createElement("th");
      actionsHeader.textContent = "";
      headerRow.appendChild(actionsHeader);
    }

    function validateNumberInput(event) {
      const value = event.target.textContent;

      if (value !== "" && isNaN(parseFloat(value))) {
        event.target.classList.add("error");
      } else {
        event.target.classList.remove("error");
      }
    }

    function updateData(event) {
      const cell = event.target;
      const rowIndex = parseInt(cell.dataset.row);
      const columnName = cell.dataset.column;
      const value = cell.textContent.trim();

      if (!isNaN(rowIndex) && columnName) {
        const column = columns.find((col) => col.name === columnName);

        if (column.type === "number") {
          if (value === "" || isNaN(parseFloat(value))) {
            data[rowIndex][columnName] = 0;
            cell.textContent = "0";
          } else {
            data[rowIndex][columnName] = parseFloat(value);
          }
        } else {
          data[rowIndex][columnName] = value;
        }
        markUnsavedChanges();
        notifyDataUpdated();
      }
    }

    function addRow() {
      const newRow = {};

      columns.forEach((column) => {
        if (column.type === "number") {
          newRow[column.name] = 0;
        } else {
          newRow[column.name] = "";
        }
      });

      data.push(newRow);
      renderDataTable();
      notifyDataUpdated();
    }

    function deleteRow(rowIndex) {
      data.splice(rowIndex, 1);
      renderDataTable();
      notifyDataUpdated();
    }

    function handleFileImport(event) {
      const file = event.target.files[0];

      if (file) {
        const reader = new FileReader();

        reader.onload = function (e) {
          const content = e.target.result;
          parseCSV(content);
        };

        reader.readAsText(file);
      }
    }

    function parseCSV(csvContent) {
      const lines = csvContent.split(/\r\n|\n/);

      if (lines.length < 2) {
        return;
      }

      // Parse CSV with proper handling of quoted fields
      function parseCSVLine(line) {
        const result = [];
        let current = '';
        let inQuotes = false;

        for (let i = 0; i < line.length; i++) {
          const char = line[i];

          if (char === '"') {
            if (inQuotes && line[i + 1] === '"') {
              // Escaped quote
              current += '"';
              i++; // Skip next quote
            } else {
              // Toggle quote state
              inQuotes = !inQuotes;
            }
          } else if (char === ',' && !inQuotes) {
            // Field separator
            result.push(current.trim());
            current = '';
          } else {
            current += char;
          }
        }

        // Add the last field
        result.push(current.trim());
        return result;
      }

      // Extract headers
      const headers = parseCSVLine(lines[0]);

      // Reset columns
      columns = [];
      headers.forEach((header) => {
        // Try to determine if it's likely a number column
        const isLikelyNumber = [
          "hp",
          "attack",
          "defense",
          "specialattack",
          "specialdefense",
          "speed",
          "id"
        ].includes(header.toLowerCase());

        columns.push({
          name: header,
          type: isLikelyNumber ? "number" : "text",
          editable: true,
        });
      });

      // Parse data rows
      data = [];
      for (let i = 1; i < lines.length; i++) {
        if (lines[i].trim() === "") continue;

        const values = parseCSVLine(lines[i]);
        const rowData = {};

        headers.forEach((header, index) => {
          const value = values[index] || "";

          if (columns[index].type === "number") {
            rowData[header] = value !== "" ? parseFloat(value) : 0;
          } else {
            rowData[header] = value;
          }
        });

        data.push(rowData);
      }

      renderDataTable();
      notifyDataUpdated();

      fileInput.value = "";
    }

    async function exportToCsv() {
      const headers = columns.map((col) => col.name).join(",");
      const rows = data.map((row) => {
        return columns
          .map((col) => {
            let value = row[col.name] !== undefined ? row[col.name] : "";
            // Always quote the Flavor field or if the value contains special characters
            if (
              col.name === "Flavor" ||
              (typeof value === "string" &&
                (value.includes(",") ||
                  value.includes('"') ||
                  value.includes("\n") ||
                  value.includes("\r")))
            ) {
              value = `"${String(value).replace(/"/g, '""')}"`;
            }
            return value;
          })
          .join(",");
      });

      const csvContent = [headers, ...rows].join("\n");

      try {
        await fs.writeTextFile("mons.csv", csvContent, {
          dir: fs.BaseDirectory.Runtime,
        });
      } catch (error) {
        // Web fallback
        const blob = new Blob([csvContent], { type: "text/csv" });
        const url = window.URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "mons.csv";
        a.click();
        window.URL.revokeObjectURL(url);
      }
      markChangesSaved();
      notifyDataUpdated();
    }

    async function exportToJs() {
      if (data.length === 0) return;

      const jsContent = `export const defaultMonsterData = {
        columns: ${JSON.stringify(columns, null, 2)},
        data: ${JSON.stringify(data, null, 2)}
      };`;

      try {
        await fs.writeTextFile("default-data.js", jsContent, {
          dir: fs.BaseDirectory.Runtime,
        });
      } catch (error) {
        // Web fallback
        const blob = new Blob([jsContent], { type: "application/javascript" });
        const url = window.URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "default-data.js";
        a.click();
        window.URL.revokeObjectURL(url);
      }
      markChangesSaved();
      notifyDataUpdated();
    }

    function applyCellHeatmap(cell, value, minValue, maxValue) {
      const normalized = (value - minValue) / (maxValue - minValue);
      const intensity = Math.floor(normalized * 40); // Using 40 for very light colors
      cell.style.backgroundColor = `rgba(65, 105, 225, ${intensity}%)`;
    }

    function updateStatsHeatmap() {
      // Get all numeric columns
      const numericColumns = columns.filter(
        (col) => col.type === "number"
      );

      // Calculate min/max for each column
      numericColumns.forEach((column) => {
        const values = data.map((row) => parseFloat(row[column.name]) || 0);
        const minValue = Math.min(...values);
        const maxValue = Math.max(...values);

        // Apply heatmap to each cell in the column
        data.forEach((_, rowIndex) => {
          const cell = document.querySelector(
            `td[data-row="${rowIndex}"][data-column="${column.name}"]`
          );
          if (cell) {
            const value = parseFloat(cell.textContent) || 0;
            applyCellHeatmap(cell, value, minValue, maxValue);
          }
        });
      });
    }

    function sortData(columnName, ascending = true) {
      data.sort((a, b) => {
        const aValue = a[columnName];
        const bValue = b[columnName];

        if (columns.find((col) => col.name === columnName).type === "number") {
          return ascending
            ? (parseFloat(aValue) || 0) - (parseFloat(bValue) || 0)
            : (parseFloat(bValue) || 0) - (parseFloat(aValue) || 0);
        } else {
          return ascending
            ? String(aValue).localeCompare(String(bValue))
            : String(bValue).localeCompare(String(aValue));
        }
      });

      renderDataTable();
      updateStatsHeatmap();
    }
  });
});
