-- SERVICES
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- PACKAGES
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Modules = ReplicatedStorage:WaitForChild("Client"):WaitForChild("Modules")
local Janitor = require(Packages.Janitor)
local Networker = require(Packages.Networker)
local Particles = require(Modules.Particles)
local Sound = require(Modules.Sound)

-- CONSTANTS
local PAUSE_GRACE_PERIOD = 0.25
local HIT_VFX_DURATION = 1.2

-- CLASS
local FreezeController = {}
FreezeController.__index = FreezeController

-- CONSTRUCTOR
function FreezeController.new(Character, Manager)
	local self = setmetatable({}, FreezeController)
	self.Character = Character
	self.Manager = Manager
	self.Janitor = Janitor.new()
	self.States = {} -- [Humanoid] = { Janitor, VisualTweens, LastMeltTime, IceModel, Highlight }
	self.IceModelToHumanoid = {} -- reverse map for O(1) lookups
	self.HumanoidByUserId = {} -- [UserId] -> Humanoid, for cleanup when Humanoid ref is nil
	self.LastMeltVFXTime = 0

	local Assets = ReplicatedStorage:WaitForChild("Assets")
	local VFXFolder = Assets:WaitForChild("Models"):WaitForChild("VFX")

	-- Cache the Frozen burst VFX particle controller
	local FrozenTemplate = VFXFolder:FindFirstChild("Frozen")
	if FrozenTemplate then
		self.FrozenParticle = Particles.new(FrozenTemplate, {
			Weld = false,
			ForceWorkspaceParent = true,
		})
	else
		warn("[FreezeController] Assets.Models.VFX.Frozen template not found")
	end

	-- Cache the Melter/MelterFinish VFX particle controllers
	self.MelterParticles = {}
	for i = 1, 2 do
		local Template = VFXFolder:FindFirstChild("Melter" .. i)
		if Template then
			self.MelterParticles[i] = Particles.new(Template, {
				Duration = 0.6,
				Weld = true,
			})
		end
	end

	local MelterFinishTemplate = VFXFolder:FindFirstChild("MelterFinish")
	if MelterFinishTemplate then
		self.MelterFinishParticle = Particles.new(MelterFinishTemplate, {
			Duration = 4,
			Weld = true,
		})
	end

	local MeltingTemplate = VFXFolder:FindFirstChild("Melting")
	if MeltingTemplate then
		self.MeltingParticle = Particles.new(MeltingTemplate, {
			Weld = true,
			ForceWorkspaceParent = true,
		})
	else
		warn("[FreezeController] Assets.Models.VFX.Melting template not found")
	end

	return self
end

function FreezeController:Initialize()
	self.FreezeNetworker = Networker.client.new("FreezeService", self)
	print("[FreezeController] Initialized")
end

-- NETWORK LISTENERS
-- Called when a player becomes frozen (server to all clients).
function FreezeController:FreezeStart(Humanoid, Stage, FinalCF)
	self:SetupHumanoid(Humanoid)
	self:ApplyFrozenVisuals(Humanoid)
	self:UpdateIceVisual(Humanoid, Stage, nil, FinalCF)
	Humanoid.AutoRotate = false

	-- Emit freeze burst VFX on the Ice Block itself
	if self.FrozenParticle then
		local State = self.States[Humanoid]
		if State and State.IceModel then
			local TargetPart = State.IceModel.PrimaryPart or State.IceModel:FindFirstChild("Hitbox")
			if TargetPart then
				self.FrozenParticle:Emit(TargetPart)
			end
		end
	end
end

-- Called when a player is fully unfrozen/melted (server to all clients).
function FreezeController:FreezeEnd(Humanoid)
	self:ThawVisuals(Humanoid)

	if self.MelterFinishParticle then
		local RootPart = Humanoid and Humanoid.Parent and Humanoid.Parent:FindFirstChild("HumanoidRootPart")
		if RootPart then
			self.MelterFinishParticle:Emit(RootPart)
		end
	end
end

-- Called by the server to force cleanup of visuals (e.g. death while frozen).
-- UserId is sent as a stable fallback because Humanoid may be nil on the client if the character was already destroyed by the time this remote arrives.
function FreezeController:CleanupVisuals(Humanoid, UserId)
	if Humanoid then
		self:CleanupHumanoid(Humanoid)
		return
	end

	-- if Humanoid ref is nil, use UserId to find the matching state
	if UserId then
		local CachedHumanoid = self.HumanoidByUserId[UserId]
		if CachedHumanoid then
			self:CleanupHumanoid(CachedHumanoid)
		end
		self.HumanoidByUserId[UserId] = nil
	end
end

-- Called by the server to play a sound on all clients.
function FreezeController:PlaySound(SoundName)
	Sound:Play(SoundName)
end

-- Called each time the melter hits a frozen player.
function FreezeController:MeltHit(Humanoid)
	local State = self.States[Humanoid]
	if not State then
		return
	end

	State.LastMeltTime = os.clock()
	self:UpdateMeltingState(Humanoid, true)

	-- Start or maintain the continuous Melting VFX
	if not State.MeltingVFX and self.MeltingParticle then
		local TargetPart = State.IceModel and (State.IceModel.PrimaryPart or State.IceModel:FindFirstChild("Hitbox"))
		if TargetPart then
			State.MeltingVFX = self.MeltingParticle:Start(TargetPart)
			-- Start returns the clone, we add it to the janitor just in case of abrubt destroyed player issues
			if State.MeltingVFX then
				State.Janitor:Add(State.MeltingVFX, "Destroy", "MeltingVFX")
			end
		end
	end

	-- if the melter stops hitting the frozen player, the melting will stop after PAUSE_GRACE_PERIOD
	task.delay(PAUSE_GRACE_PERIOD, function()
		if self.States[Humanoid] == State then
			if (os.clock() - State.LastMeltTime) >= PAUSE_GRACE_PERIOD then
				self:UpdateMeltingState(Humanoid, false)

				-- Stop emitters smoothly
				if State.MeltingVFX and self.MeltingParticle then
					self.MeltingParticle:Stop(State.MeltingVFX)
					State.Janitor:Remove("MeltingVFX")
					State.MeltingVFX = nil
				end
			end
		end
	end)
end

-- Called when a player receives a sword hit (plays a brief highlight flash).
function FreezeController:PlayHitVFX(VictimHumanoid)
	local Parent = VictimHumanoid and VictimHumanoid.Parent
	if not Parent then
		return
	end

	local Highlight = Instance.new("Highlight")
	Highlight.Name = "HitFlash"
	Highlight.FillColor = Color3.fromRGB(0, 255, 255)
	Highlight.FillTransparency = 0.2
	Highlight.OutlineColor = Color3.fromRGB(0, 255, 255)
	Highlight.OutlineTransparency = 0
	Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	Highlight.Parent = Parent

	local Tween = TweenService:Create(
		Highlight,
		TweenInfo.new(HIT_VFX_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	)
	Tween:Play()
	Debris:AddItem(Highlight, HIT_VFX_DURATION)
end

-- Called to play a one-shot particle VFX at a target part.
function FreezeController:PlayVFX(VFXName, TargetPart)
	local Assets = ReplicatedStorage:WaitForChild("Assets")
	local VFXFolder = Assets:WaitForChild("Models"):WaitForChild("VFX")
	local Template = VFXFolder:FindFirstChild(VFXName)

	if Template and TargetPart then
		Particles.new(Template, { Duration = 0.1, Weld = false }):Emit(TargetPart)
	else
		warn("[FreezeController] Template or TargetPart missing:", VFXName, TargetPart)
	end
end

-- Returns whether the given Humanoid currently has an active freeze state.
function FreezeController:IsFrozen(Humanoid)
	return self.States[Humanoid] ~= nil
end

-- Reverse-lookup: given an ice block model, returns the owning Humanoid (or nil).
function FreezeController:GetHumanoidFromIceModel(IceModel)
	return self.IceModelToHumanoid[IceModel]
end

-- Registers a Humanoid and sets up cleanup listeners.
function FreezeController:SetupHumanoid(Humanoid)
	if self.States[Humanoid] then
		return
	end

	local HumanoidJanitor = Janitor.new()

	HumanoidJanitor:Add(Humanoid.AncestryChanged:Connect(function()
		if not Humanoid:IsDescendantOf(workspace) then
			self:CleanupHumanoid(Humanoid)
		end
	end))

	-- Cache UserId so we can look up this state even when the Humanoid ref goes nil
	local Character = Humanoid.Parent
	if Character then
		local Player = Players:GetPlayerFromCharacter(Character)
		if Player then
			self.HumanoidByUserId[Player.UserId] = Humanoid
		end
	end

	self.States[Humanoid] = {
		Janitor = HumanoidJanitor,
		VisualTweens = {},
		LastMeltTime = 0,
		IceModel = nil,
		MeltingVFX = nil,
	}
end

-- Applies the frozen highlight to the character.
function FreezeController:ApplyFrozenVisuals(Humanoid)
	local State = self.States[Humanoid]
	if not State then
		return
	end

	self:ClearVisuals(State)

	local Parent = Humanoid.Parent
	if not Parent then
		return
	end

	local Highlight = Instance.new("Highlight")
	Highlight.Name = "FreezeHighlight"
	Highlight.FillColor = Color3.fromRGB(152, 222, 255)
	Highlight.FillTransparency = 0.8
	Highlight.OutlineColor = Color3.fromRGB(100, 200, 255)
	Highlight.OutlineTransparency = 0.4
	Highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	Highlight.Parent = Parent

	State.Highlight = Highlight

	State.Janitor:Add(function()
		if State.Highlight and not State.ThawingHighlight then
			State.Highlight:Destroy()
			State.Highlight = nil
		end
	end, true, Highlight)
end

-- Spawns/replaces the ice block model for the given freeze Stage.
function FreezeController:UpdateIceVisual(Humanoid, Stage, OldStage, FinalCF)
	local Character = Humanoid and Humanoid.Parent
	if not Character then
		return
	end

	local State = self.States[Humanoid]
	if not State then
		return
	end

	local RootPart = Character:FindFirstChild("HumanoidRootPart")
	if not RootPart then
		return
	end

	-- Load stage template
	local Assets = ReplicatedStorage:WaitForChild("Assets")
	local StagesFolder = Assets:FindFirstChild("Models") and Assets.Models:FindFirstChild("FreezeStages")
	local PlayerStages = StagesFolder and StagesFolder:FindFirstChild("PlayerStages")
	local Template = PlayerStages and PlayerStages:FindFirstChild(tostring(Stage))
	if not Template then
		return
	end

	-- Save the prior block's position, then discard it
	if State.IceModel then
		State.IceModel:Destroy()
		State.IceModel = nil
	end

	-- Prepare new block
	local NewBlock = Template:Clone()
	NewBlock.Name = "IceBlock_Visual_Client"
	for _, Descendant in ipairs(NewBlock:GetDescendants()) do
		if Descendant:IsA("BasePart") or Descendant:IsA("MeshPart") then
			Descendant.CanQuery = true
			Descendant.Massless = true
			Descendant.CanCollide = (Descendant.Name == "Base")
			if Descendant.Name == "Hitbox" then
				Descendant.Transparency = 1
			end
		end
	end

	-- Update cached CFrame
	if FinalCF then
		State.FreezeCFrame = FinalCF
	end

	-- Place block
	if Stage == 5 and State.FreezeCFrame then
		NewBlock:PivotTo(State.FreezeCFrame)

		-- If anchored to a specific world position, don't weld to the player
		local TargetPart = NewBlock.PrimaryPart or NewBlock:FindFirstChild("Hitbox")
		if TargetPart then
			TargetPart.Anchored = true
		end
	else
		NewBlock:PivotTo(Character:GetPivot())

		local Weld = Instance.new("WeldConstraint")
		Weld.Part0 = RootPart
		Weld.Part1 = NewBlock.PrimaryPart or NewBlock:FindFirstChild("Hitbox")
		Weld.Parent = NewBlock
	end

	NewBlock.Parent = workspace:FindFirstChild("Debris") or workspace

	-- Update reverse map
	if State.IceModel then
		self.IceModelToHumanoid[State.IceModel] = nil
	end
	State.IceModel = NewBlock
	self.IceModelToHumanoid[NewBlock] = Humanoid

	-- Stage-change VFX (sound is fired by server via PlaySound)
	if OldStage then
		if #self.MelterParticles > 0 then
			local TargetPart = NewBlock.PrimaryPart or NewBlock:FindFirstChild("Hitbox")
			if TargetPart then
				local Particle = self.MelterParticles[math.random(1, #self.MelterParticles)]
				if Particle then
					Particle:Emit(TargetPart, { EmitCount = 1 })
				end
			end
		end
	end

	-- Fade highlight to show freeze progression (Stage 1 = faint, Stage 5 = vivid)
	if State.Highlight then
		local Target = math.clamp(0.8 - ((Stage - 1) * 0.15), 0.2, 0.8)
		TweenService:Create(
			State.Highlight,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ FillTransparency = Target, OutlineTransparency = Target / 2 }
		):Play()
	end
end

-- Plays the thaw animation and removes freeze visuals.
function FreezeController:ThawVisuals(Humanoid)
	local State = self.States[Humanoid]
	if not State then
		return
	end

	Humanoid.AutoRotate = true

	for _, Tween in ipairs(State.VisualTweens) do
		Tween:Cancel()
	end
	table.clear(State.VisualTweens)

	if State.Highlight then
		TweenService:Create(
			State.Highlight,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ FillTransparency = 1, OutlineTransparency = 1 }
		):Play()
		Debris:AddItem(State.Highlight, 0.6)
		State.ThawingHighlight = true
		State.Janitor:Remove(State.Highlight)
		State.Highlight = nil
	end

	if State.IceModel then
		State.IceModel:Destroy()
		State.IceModel = nil
	end

	self:CleanupHumanoid(Humanoid)
end

-- Pauses or resumes visual tweens while the player is being actively melted.
function FreezeController:UpdateMeltingState(Humanoid, IsMelting)
	local State = self.States[Humanoid]
	if not State then
		return
	end

	for _, Tween in ipairs(State.VisualTweens) do
		if IsMelting then
			Tween:Pause()
		else
			Tween:Play()
		end
	end
end

-- CLEANUP

-- Destroys all visuals tracked in State without cleaning up the humanoid entry.
function FreezeController:ClearVisuals(State)
	for _, Tween in ipairs(State.VisualTweens) do
		Tween:Cancel()
	end
	table.clear(State.VisualTweens)

	if State.Highlight then
		State.Highlight:Destroy()
		State.Highlight = nil
	end

	if State.MeltingVFX then
		if self.MeltingParticle then
			self.MeltingParticle:Stop(State.MeltingVFX)
		end
		State.MeltingVFX = nil
	end

	if State.IceModel then
		self.IceModelToHumanoid[State.IceModel] = nil
		State.IceModel:Destroy()
		State.IceModel = nil
	end
end

-- Removes all state and visuals for the given Humanoid.
function FreezeController:CleanupHumanoid(Humanoid)
	local State = self.States[Humanoid]
	if not State then
		return
	end

	if State.IceModel then
		self.IceModelToHumanoid[State.IceModel] = nil
		State.IceModel:Destroy()
		State.IceModel = nil
	end

	if State.MeltingVFX then
		if self.MeltingParticle then
			self.MeltingParticle:Stop(State.MeltingVFX)
		end
		State.MeltingVFX = nil
	end

	if State.Highlight then
		State.Highlight:Destroy()
	end
	State.Janitor:Destroy()
	self.States[Humanoid] = nil

	-- Remove from UserId reverse-map
	if Humanoid.Parent then
		local Player = Players:GetPlayerFromCharacter(Humanoid.Parent)
		if Player and self.HumanoidByUserId then
			self.HumanoidByUserId[Player.UserId] = nil
		end
	end
end

function FreezeController:Destroy()
	if self.FreezeNetworker then
		self.FreezeNetworker:destroy()
	end

	-- Clean up all tracked states including their ice models
	for _, State in pairs(self.States) do
		if State.IceModel then
			self.IceModelToHumanoid[State.IceModel] = nil
			State.IceModel:Destroy()
			State.IceModel = nil
		end
		State.Janitor:Destroy()
	end
	self.Janitor:Destroy()
	self.HumanoidByUserId = nil
	self.IceModelToHumanoid = nil
	self.States = nil
	setmetatable(self, nil)
end

return FreezeController
