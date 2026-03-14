-- SERVICES
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- PACKAGES / ASSETS
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Assets = ReplicatedStorage:WaitForChild("Assets")

-- MODULES
local Networker = require(Packages.Networker)
local Janitor = require(Packages.Janitor)
local Signal = require(Packages.Signal)

local Modules = ReplicatedStorage.Client.Modules
local Raycaster = require(Modules.Raycaster)

local CombatConstants = require(ReplicatedStorage.Client.Player.Combat.Constants.CombatConstants)

-- CONSTANTS
local RECOVERY_DELAY = 10 -- Seconds before speed starts recovering
local START_SPEED = 18 -- Default walk speed
local FROZEN_SPEED = 0 -- Walk speed when frozen

local MAX_FREEZE_DURATION = CombatConstants.Freeze.MaxDuration
local MAX_FREEZE_HEALTH = 5
local PAUSE_GRACE_PERIOD = 0.2

local GROUND_OFFSET = Vector3.new(0, 3.4, 0)

-- CLASS
local FreezeService = {}
FreezeService.__index = FreezeService

-- CONSTRUCTOR
function FreezeService.new()
	local self = setmetatable({}, FreezeService)

	self.Janitor = Janitor.new()
	self.PlayerStates = {}
	self.KoInfoByUserId = {}
	self.PlayerStateChanged = Signal.new()

	-- Cache Player Templates (1 to 5)
	self.IceTemplates = {}
	local StagesFolder = Assets:FindFirstChild("Models") and Assets.Models:FindFirstChild("FreezeStages")

	if StagesFolder then
		-- Player Stages
		local PlayerStages = StagesFolder:FindFirstChild("PlayerStages")
		if PlayerStages then
			for i = 1, 5 do
				local Template = PlayerStages:FindFirstChild(tostring(i))
				if Template then
					self.IceTemplates[i] = Template
				end
			end
		end

		self.UIPartTemplate = StagesFolder:FindFirstChild("UIPart")
	else
		warn("[FreezeService] Assets.Models.FreezeStages not found")
	end

	return self
end

function FreezeService:Initialize()
	self.Networker = Networker.server.new("FreezeService", self)

	self.EquipmentService = self.Manager:GetController("EquipmentService")
	self.PointsService = self.Manager:GetController("PointsService")

	-- Heartbeat for Recovery
	self.Janitor:Add(RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end))

	-- Cleanup on Player Removing
	self.Janitor:Add(Players.PlayerRemoving:Connect(function(Player)
		self:CleanupPlayer(Player)
	end))

	print("[FreezeService] Initialized")
end

--// PUBLIC METHODS //--
function FreezeService:ResetAll()
	print("[FreezeService] Resetting all player states...")
	for Humanoid, _ in pairs(self.PlayerStates) do
		self:CleanupHumanoid(Humanoid)
	end
	table.clear(self.PlayerStates)
	table.clear(self.KoInfoByUserId)
end

function FreezeService:ApplyHit(VictimHumanoid, AttackerCharacter, HitAmount, WeaponName, WeaponImage)
	if not VictimHumanoid then
		return
	end

	local State = self:_GetState(VictimHumanoid)
	local Now = workspace:GetServerTimeNow()

	State.LastHitTime = Now

	-- Track Attacker
	if AttackerCharacter then
		local AttackerPlayer = Players:GetPlayerFromCharacter(AttackerCharacter)
		if AttackerPlayer then
			State.LastAttacker = AttackerPlayer
		end
	end

	if State.IsFrozen then
		return -- Already frozen
	end

	self.Networker:fireAll("PlayHitVFX", VictimHumanoid)

	local hitAmt = HitAmount or 1
	local WasFirstHit = State.HitCount == 0

	self:AddHitCount(VictimHumanoid, State, hitAmt)

	-- Apply knockback on first hit
	if WasFirstHit then
		self:ApplyKnockback(VictimHumanoid, AttackerCharacter)
	end

	-- Freeze player on third hit
	if State.HitCount >= 3 then
		-- Store weapon used to freeze for KO card
		State.LastFreezeWeaponName = WeaponName
		State.LastFreezeWeaponImage = WeaponImage
		self:ApplyFreeze(VictimHumanoid, State)

		-- POINTS: Freeze Player
		local AttackerPlayer = Players:GetPlayerFromCharacter(AttackerCharacter)
		local VictimPlayer = VictimHumanoid and Players:GetPlayerFromCharacter(VictimHumanoid.Parent)
		local VictimName = VictimPlayer and (VictimPlayer.DisplayName or VictimPlayer.Name) or nil
		if AttackerPlayer and self.PointsService then
			self.PointsService:Award(AttackerPlayer, "Freeze", VictimName)
		end
	else
		-- POINTS: Hit Player
		local AttackerPlayer = Players:GetPlayerFromCharacter(AttackerCharacter)
		if AttackerPlayer and self.PointsService then
			self.PointsService:Award(AttackerPlayer, "Hit")
		end
	end
end

function FreezeService:IsPlayerFrozen(Humanoid)
	if not Humanoid then
		return false
	end
	local State = self.PlayerStates[Humanoid]
	return State and State.IsFrozen
end

function FreezeService:Melt(Target, Amount, TeamId, Instigator)
	local State = self.PlayerStates[Target]

	-- 1. Player Logic
	if not State and Target:IsA("Humanoid") then
		State = self:_GetState(Target)
	end

	if not State.IsFrozen then
		return
	end

	if Target.Health <= 0 then
		return
	end

	local Now = workspace:GetServerTimeNow()
	State.LastHitTime = Now -- Reset recovery timer while being melted
	State.LastMeltInteraction = Now -- Reset death timer pause

	if Now - (State.LastMeltHitNetworkTime or 0) > 0.15 then
		State.LastMeltHitNetworkTime = Now
		self.Networker:fireAll("MeltHit", Target)
	end

	-- Gameplay-linked UI/KO behavior:
	-- Melting restores death timer progress so frozen percent crawls down.
	-- Recalculate timestamp based on new remaining time
	local TimerRestore = (Amount / MAX_FREEZE_HEALTH) * MAX_FREEZE_DURATION
	State.FreezeDeathTimer = math.clamp(State.FreezeDeathTimer + TimerRestore, 0, MAX_FREEZE_DURATION)

	-- Update Timestamp for clients
	State.FreezeDeathTimestamp = Now + State.FreezeDeathTimer
	self.PlayerStateChanged:Fire()

	local OldStage = math.ceil(State.FreezeHealth)
	State.FreezeHealth = math.max(0, State.FreezeHealth - Amount)
	local NewStage = math.ceil(State.FreezeHealth)

	if NewStage < OldStage then
		if NewStage <= 0 then
			-- Unfreeze
			self:Unfreeze(Target, State, Instigator)
		else
			-- Notify all clients: update visual stage + play stage-change sound
			self.Networker:fireAll("UpdateIceVisual", Target, NewStage, OldStage, State.FreezeCFrame)
			self.Networker:fireAll("PlaySound", "Melt")
		end
	end
end

--// PRIVATE METHODS //--

function FreezeService:AddHitCount(Humanoid, State, HitAmount)
	State.HitCount += (HitAmount or 1)

	self.PlayerStateChanged:Fire()
	self.Networker:fireAll("PlayVFX", "SwordSlash1", Humanoid.RootPart)
end

function FreezeService:ApplyFreeze(Humanoid, State)
	State.HitCount = 3
	State.IsFrozen = true
	State.FreezeHealth = MAX_FREEZE_HEALTH -- Max Health/Stage
	State.CurrentSpeed = FROZEN_SPEED

	-- Reset Death Timer
	State.FreezeDeathTimer = MAX_FREEZE_DURATION
	State.FreezeDeathTimestamp = workspace:GetServerTimeNow() + MAX_FREEZE_DURATION
	State.LastMeltInteraction = 0
	Humanoid.WalkSpeed = FROZEN_SPEED
	Humanoid.BreakJointsOnDeath = false -- Prevent exploding on death

	-- Stop Animations
	Humanoid.PlatformStand = true

	local Root = Humanoid.Parent:FindFirstChild("HumanoidRootPart")

	-- Calculate Safe Spawn and Teleport Victim
	local FinalPosition = nil
	if Root then
		local ModelSize = Vector3.new(8, 7, 8) -- Fallback incase it fails
		if self.IceTemplates[5] then
			ModelSize = self.IceTemplates[5]:GetExtentsSize()
		end

		-- Add a small buffer for safety
		ModelSize += Vector3.new(1, 1, 1)

		-- The victim's character gets excluded so we can place the ice safely on them without overlapping their own collision body
		-- OTHER players should NOT be excluded, so GetSafePlacement correctly avoids freezing players inside each other.
		local ExcludeList = {}
		if Humanoid.Parent then
			table.insert(ExcludeList, Humanoid.Parent)
		end

		-- Get final position for the ice block
		local BasePos = Raycaster.GetGroundBelow(Root.Position, ExcludeList)
		local BaseCF = BasePos and (CFrame.new(BasePos) + GROUND_OFFSET) or Root.CFrame
		FinalPosition = Raycaster.GetSafePlacement(BaseCF, ModelSize, ExcludeList, GROUND_OFFSET)
		Root.CFrame = FinalPosition
		Root.Anchored = true
	end

	State.FreezeCFrame = FinalPosition

	-- Disarm Player and block re-equip until unfrozen or Transition
	local Player = Players:GetPlayerFromCharacter(Humanoid.Parent)
	if Player and self.EquipmentService then
		self.EquipmentService:Unequip(Player)
		self.EquipmentService:SetWeaponsDisabled(Player, true)
	end

	-- Create Visuals + play freeze sound for all clients
	self.Networker:fireAll("FreezeStart", Humanoid, 5, FinalPosition)
	self.Networker:fireAll("PlaySound", "Freeze")

	self.Networker:fireAll("PlayVFX", "SwordSlash2", Humanoid.RootPart)
	self.PlayerStateChanged:Fire()
end

function FreezeService:ApplyKnockback(VictimHumanoid, AttackerCharacter)
	local KnockbackConfig = CombatConstants.SwordSlash.Knockback

	local VictimRoot = VictimHumanoid.Parent and VictimHumanoid.Parent:FindFirstChild("HumanoidRootPart")
	local AttackerRoot = AttackerCharacter and AttackerCharacter:FindFirstChild("HumanoidRootPart")

	if not VictimRoot or not AttackerRoot then
		return
	end

	-- Calculate Direction
	local Direction = (VictimRoot.Position - AttackerRoot.Position).Unit
	Direction = Vector3.new(Direction.X, 0, Direction.Z).Unit

	-- Calculate Force Vector with Vertical Angle
	local Radians = math.rad(KnockbackConfig.VerticalAngle)
	local ForceVector = (Direction * math.cos(Radians) + Vector3.new(0, math.sin(Radians), 0)) * KnockbackConfig.Force

	-- Create Attachment if needed
	local Attachment = VictimRoot:FindFirstChild("KnockbackAtt")
	if not Attachment then
		Attachment = Instance.new("Attachment")
		Attachment.Name = "KnockbackAtt"
		Attachment.Parent = VictimRoot
	end

	local LinearVelocity = Instance.new("LinearVelocity")
	LinearVelocity.Name = "KnockbackVelocity"
	LinearVelocity.Attachment0 = Attachment
	LinearVelocity.MaxForce = 100000 -- High enough to overcome friction/gravity momentarily
	LinearVelocity.VectorVelocity = ForceVector
	LinearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	LinearVelocity.Parent = VictimRoot

	Debris:AddItem(LinearVelocity, KnockbackConfig.Duration)
	Debris:AddItem(Attachment, KnockbackConfig.Duration)
end

function FreezeService:Unfreeze(Humanoid, State, Instigator)
	State.IsFrozen = false
	State.HitCount = 0
	State.FreezeHealth = 0
	State.CurrentSpeed = START_SPEED

	-- Unanchor
	local Root = Humanoid.Parent:FindFirstChild("HumanoidRootPart")
	if Root then
		Root.Anchored = false
	end

	-- Notify Clients + play melt-finish sound for all clients
	self.Networker:fireAll("FreezeEnd", Humanoid)
	self.Networker:fireAll("PlaySound", "Melt")

	Humanoid.WalkSpeed = START_SPEED
	Humanoid.BreakJointsOnDeath = true -- Restore default behavior
	Humanoid.PlatformStand = false

	if State.AnimateScript then
		State.AnimateScript.Disabled = false
		State.AnimateScript = nil
	end

	self.PlayerStateChanged:Fire()

	if State.IceModel then
		self.IceModelToHumanoid[State.IceModel] = nil

		State.IceModel:Destroy()
		State.IceModel = nil
	end

	if State.UIPart then
		State.UIPart:Destroy()
		State.UIPart = nil
	end

	-- Reallow weapons for unfrozen player
	local TargetPlayer = Humanoid and Humanoid.Parent and Players:GetPlayerFromCharacter(Humanoid.Parent)
	if TargetPlayer and self.EquipmentService then
		self.EquipmentService:SetWeaponsDisabled(TargetPlayer, false)
	end

	-- POINTS: Unfreeze Player (Humanoid = player who was melted)
	local TargetName = TargetPlayer and (TargetPlayer.DisplayName or TargetPlayer.Name) or nil
	if Instigator and self.PointsService then
		self.PointsService:Award(Instigator, "Unfreeze", TargetName)
	end
end

function FreezeService:Update(dt)
	local Now = workspace:GetServerTimeNow()

	for Target, State in pairs(self.PlayerStates) do
		-- HANDLE PLAYER
		if not Target.Parent or (Target.Health <= 0 and not State.IsFrozen) then
			if not Target.Parent then
				self:CleanupHumanoid(Target)
			end
			continue
		end

		-- If Frozen, Handle Death Timer
		if State.IsFrozen then
			-- When not paused, decrement timer and maybe broadcast percent
			if (Now - State.LastMeltInteraction) > PAUSE_GRACE_PERIOD then
				State.FreezeDeathTimer = State.FreezeDeathTimer - dt

				if State.FreezeDeathTimer <= 0 then -- Times up
					-- Persist KO info for KOCard before clearing state (victim userId -> koByUserId, weapon)
					local VictimPlayer = Target.Parent and Players:GetPlayerFromCharacter(Target.Parent)
					if VictimPlayer and VictimPlayer.UserId then
						self.KoInfoByUserId[VictimPlayer.UserId] = {
							koByUserId = State.LastAttacker and State.LastAttacker.UserId or nil,
							koWeaponName = State.LastFreezeWeaponName or "Unknown",
							koWeaponImage = State.LastFreezeWeaponImage or nil,
						}
					end
					Target.Health = 0
					self.PlayerStateChanged:Fire()
					-- DO NOT Cleanup here. Cleanup happens when Character is destroyed.
				end
			end
			continue
		end

		if State.HitCount > 0 and (Now - State.LastHitTime > RECOVERY_DELAY) then
			-- Recover HitCount by 1 and reset delay timer for next recovery
			State.HitCount -= 1
			State.LastHitTime = Now
			self.PlayerStateChanged:Fire()
		end
	end
end

function FreezeService:CleanupHumanoid(Humanoid)
	if not Humanoid then
		return
	end

	local State = self.PlayerStates[Humanoid]
	if State then
		-- Tell all clients to clean up visuals (like the Ice Block).
		-- We send the player UserId as a stable identifier because the Humanoid reference may be nil on clients by the time this remote arrives (the character is being destroyed during the same frame).
		if self.Networker then
			local UserId = nil
			if Humanoid.Parent then
				local Player = Players:GetPlayerFromCharacter(Humanoid.Parent)
				if Player then
					UserId = Player.UserId
				end
			end
			self.Networker:fireAll("CleanupVisuals", Humanoid, UserId)
		end

		-- Janitor handles IceModel destruction and Connection disconnects
		if State.Janitor then
			State.Janitor:Destroy()
		end

		self.PlayerStates[Humanoid] = nil
	end
end

function FreezeService:CleanupPlayer(Player)
	if Player.Character then
		local Humanoid = Player.Character:FindFirstChild("Humanoid")
		if Humanoid then
			self:CleanupHumanoid(Humanoid)
		end
	end
end

-- HELPER: State Management
function FreezeService:_GetState(Humanoid)
	if not self.PlayerStates[Humanoid] then
		local State = {
			Humanoid = Humanoid, -- Self Reference
			Janitor = Janitor.new(),
			HitCount = 0,
			LastHitTime = 0,
			CurrentSpeed = START_SPEED,
			IsFrozen = false,
			FreezeHealth = 0, -- 0 to MAX_FREEZE_HEALTH
			FreezeCFrame = nil, -- Latest Server Position
			IceModel = nil,
			UIPart = nil,
			FreezeDeathTimer = MAX_FREEZE_DURATION,
			FreezeDeathTimestamp = nil :: number?,
			LastMeltInteraction = 0,
			LastAttacker = nil, -- Player
			LastFreezeWeaponName = nil,
			LastFreezeWeaponImage = nil,
		}

		-- Hook IceModel cleanup to Janitor
		State.Janitor:Add(function()
			if State.IceModel then
				State.IceModel:Destroy()
				State.IceModel = nil
			end
			if State.UIPart then
				State.UIPart:Destroy()
				State.UIPart = nil
			end
		end)

		-- Automatically clean up the state if the Humanoid (Player or NPC) is destroyed
		State.Janitor:Add(Humanoid.AncestryChanged:Connect(function(_, Parent)
			if not Parent then
				self:CleanupHumanoid(Humanoid)
			end
		end))

		self.PlayerStates[Humanoid] = State
	end
	return self.PlayerStates[Humanoid]
end

function FreezeService:GetLastAttacker(Humanoid)
	local State = self.PlayerStates[Humanoid]
	return State and State.LastAttacker
end

function FreezeService:Destroy()
	if self.PlayerStateChanged then
		self.PlayerStateChanged:Destroy()
	end
	self.Janitor:Destroy()
end

return FreezeService
