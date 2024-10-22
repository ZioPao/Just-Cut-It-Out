---@class ConfirmationPanel : ISPanel
local ConfirmationPanel = ISPanel:derive("ConfirmationPanel")

---Starts a new confirmation panel
---@param x number
---@param y number
---@param width number
---@param height number
---@param alertText string
---@param onConfirmFunc function
---@return ConfirmationPanel
function ConfirmationPanel:new(x, y, width, height, alertText, parentPanel, onConfirmFunc)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o:initialise()
    o.alertText = alertText
    o.onConfirmFunc = onConfirmFunc
    o.parentPanel = parentPanel
    ConfirmationPanel.instance = o

    ---@cast o ConfirmationPanel
    return o
end

function ConfirmationPanel:createChildren()
    ISPanel.createChildren(self)
    self.borderColor = { r = 1, g = 0, b = 0, a = 1 }

    self.textPanel = ISRichTextPanel:new(0, 0, self.width, self.height)
    self.textPanel:initialise()
    self:addChild(self.textPanel)
    self.textPanel.defaultFont = UIFont.Medium
    self.textPanel.anchorTop = true
    self.textPanel.anchorLeft = false
    self.textPanel.anchorBottom = true
    self.textPanel.anchorRight = false
    self.textPanel.marginLeft = 0
    self.textPanel.marginTop = 10
    self.textPanel.marginRight = 0
    self.textPanel.marginBottom = 0
    self.textPanel.autosetheight = false
    self.textPanel.background = false
    self.textPanel:setText(self.alertText)
    self.textPanel:paginate()

    local yPadding = 10
    local xPadding = self:getWidth() / 4
    local btnWidth = 100
    local btnHeight = 25

    local yButton = self:getHeight() - yPadding - btnHeight

    -- Yes button with translator
    self.btnYes = ISButton:new(xPadding, yButton, btnWidth, btnHeight, getText("IGUI_Yes"), self, self.onClick)
    self.btnYes.internal = "YES"
    self.btnYes:initialise()
    self.btnYes.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    self.btnYes:setEnable(true)
    self:addChild(self.btnYes)

    -- No button with translator
    self.btnNo = ISButton:new(self:getWidth() - xPadding - btnWidth, yButton, btnWidth, btnHeight, getText("IGUI_No"), self, self.onClick)
    self.btnNo.internal = "NO"
    self.btnNo:initialise()
    self.btnNo.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    self.btnNo:setEnable(true)
    self:addChild(self.btnNo)
end

function ConfirmationPanel:onClick(btn)
    if btn.internal == 'YES' then
        if self.onConfirmFunc then
            self.onConfirmFunc(self.parentPanel)
        end
        self:close()
    elseif btn.internal == 'NO' then
        self:close()
    end
end

-------------------------

---@param alertText string
---@param x any
---@param y any
---@param parentPanel any
---@param onConfirmFunc any
---@return ConfirmationPanel
function ConfirmationPanel.Open(alertText, x, y, parentPanel, onConfirmFunc)
    local width = 500
    local height = 120

    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()

    -- Check size to avoid exceeding screen limits
    if x + width > screenWidth then
        x = screenWidth - width
    end

    if y + height > screenHeight then
        y = screenHeight - height
    end

    local panel = ConfirmationPanel:new(x, y, width, height, alertText, parentPanel, onConfirmFunc)
    panel:initialise()
    panel:addToUIManager()
    panel:bringToTop()
    return panel
end

function ConfirmationPanel.Close()
    if ConfirmationPanel.instance then
        ConfirmationPanel.instance:close()
        ConfirmationPanel.instance = nil
    end
end

return ConfirmationPanel
