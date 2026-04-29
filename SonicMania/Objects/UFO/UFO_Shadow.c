// ---------------------------------------------------------------------
// RSDK Project: Sonic Mania
// Object Description: UFO_Shadow Object
// Object Author: Christian Whitehead/Simon Thomley/Hunter Bridges
// Decompiled by: Rubberduckycooly & RMGRich
// ---------------------------------------------------------------------

#include "Game.h"

ObjectUFO_Shadow *UFO_Shadow;

#if defined(RSDK_USE_MISTER)
extern void Scene3D_SetDrawSource(uint32 source);
#define UFO_S3D_SOURCE_SHADOW 5
#define UFO_SPECIAL_SCENE_VERT_LIMIT 0x4000
static bool32 s_shadowBatchPrepared;
static Entity *s_shadowBatchEntity;
#endif

void UFO_Shadow_Update(void) {}

void UFO_Shadow_LateUpdate(void)
{
    RSDK_THIS(UFO_Shadow);
    Entity *parent = self->parent;

    if (parent->classID) {
        self->position.x = parent->position.x;
        self->position.y = parent->position.y;

        if (RSDK.GetTile(UFO_Setup->playFieldLayer, self->position.x >> 20, self->position.y >> 20) == (uint16)-1 || parent->drawGroup != 4) {
            self->visible = false;
        }
        else {
            self->visible = true;
            int32 x       = self->position.x >> 8;
            int32 z       = self->position.y >> 8;
            Matrix *mat   = &UFO_Camera->matWorld;

            self->zdepth = mat->values[2][3] + (z * mat->values[2][2] >> 8) + (x * mat->values[2][0] >> 8);

            // MiSTer: lowered close-cull from 0x4000 to 0x100 to stop shadows
            // popping out of view when the player approached close — they
            // would still be inside the visible FOV, just close to the
            // camera plane. Matches UFO_Sphere / UFO_Ring threshold.
            if (self->zdepth >= 0x100) {
                self->visible =
                    abs((int32)((mat->values[0][3] << 8) + ((z * mat->values[0][2]) & 0xFFFFFF00) + ((x * mat->values[0][0]) & 0xFFFFFF00))
                        / self->zdepth)
                    < 0x100;
            }
        }
    }
    else {
        destroyEntity(self);
    }
}

void UFO_Shadow_StaticUpdate(void)
{
#if defined(RSDK_USE_MISTER)
    s_shadowBatchPrepared = false;
    s_shadowBatchEntity   = NULL;
#endif
}

#if defined(RSDK_USE_MISTER)
void UFO_Shadow_FlushBatch(void)
{
    if (!s_shadowBatchPrepared || !s_shadowBatchEntity)
        return;

    Entity *store = SceneInfo->entity;
    SceneInfo->entity = s_shadowBatchEntity;
    Scene3D_SetDrawSource(UFO_S3D_SOURCE_SHADOW);
    RSDK.Draw3DScene(UFO_Shadow->sceneID);
    SceneInfo->entity = store;

    s_shadowBatchPrepared = false;
    s_shadowBatchEntity   = NULL;
}
#endif

void UFO_Shadow_Draw(void)
{
    RSDK_THIS(UFO_Shadow);

    if (self->zdepth >= 0x100) {
        RSDK.MatrixScaleXYZ(&self->matrix, self->shadowScale, 0x100, self->shadowScale);
        RSDK.MatrixTranslateXYZ(&self->matrix, self->position.x, 0, self->position.y, 0);
        RSDK.MatrixMultiply(&self->matrix, &self->matrix, &UFO_Camera->matWorld);

#if defined(RSDK_USE_MISTER)
        if (!s_shadowBatchPrepared) {
            RSDK.Prepare3DScene(UFO_Shadow->sceneID);
            s_shadowBatchPrepared = true;
            s_shadowBatchEntity   = (Entity *)self;
        }
#else
        RSDK.Prepare3DScene(UFO_Shadow->sceneID);
#endif
        RSDK.AddModelTo3DScene(UFO_Shadow->modelIndex, UFO_Shadow->sceneID, S3D_SOLIDCOLOR_SCREEN, &self->matrix, 0, 0);
#if defined(RSDK_USE_MISTER)
        Scene3D_SetDrawSource(UFO_S3D_SOURCE_SHADOW);
#else
        RSDK.Draw3DScene(UFO_Shadow->sceneID);
#endif
    }
}

void UFO_Shadow_Create(void *data)
{
    RSDK_THIS(UFO_Shadow);

    if (!SceneInfo->inEditor) {
        self->inkEffect     = INK_BLEND;
        self->visible       = true;
        self->drawFX        = FX_SCALE;
        self->drawGroup     = 3;
        self->active        = ACTIVE_RBOUNDS;
        self->updateRange.x = 0x300;
        self->updateRange.y = 0x300;
    }
}

void UFO_Shadow_StageLoad(void)
{
    UFO_Shadow->modelIndex = RSDK.LoadMesh("Special/Shadow.bin", SCOPE_STAGE);
    UFO_Shadow->sceneID    = RSDK.Create3DScene("View:Special",
#if defined(RSDK_USE_MISTER)
                                                UFO_SPECIAL_SCENE_VERT_LIMIT,
#else
                                                4096,
#endif
                                                SCOPE_STAGE);

    int32 slot = TEMPENTITY_START;
    foreach_all(UFO_Player, player)
    {
        EntityUFO_Shadow *shadow = RSDK_GET_ENTITY(slot--, UFO_Shadow);
        RSDK.ResetEntity(shadow, UFO_Shadow->classID, NULL);
        shadow->position.x  = player->position.x;
        shadow->position.y  = player->position.y;
        shadow->parent      = (Entity *)player;
        shadow->shadowScale = 0x140;
    }

    foreach_all(UFO_Circuit, ufo)
    {
        if (ufo->startNode) {
            EntityUFO_Shadow *shadow = RSDK_GET_ENTITY(slot--, UFO_Shadow);
            RSDK.ResetEntity(shadow, UFO_Shadow->classID, NULL);
            shadow->position.x  = ufo->position.x;
            shadow->position.y  = ufo->position.y;
            shadow->parent      = (Entity *)ufo;
            shadow->shadowScale = 0x400;
        }
    }

    foreach_all(UFO_Ring, ring)
    {
        EntityUFO_Shadow *shadow = RSDK_GET_ENTITY(slot--, UFO_Shadow);
        RSDK.ResetEntity(shadow, UFO_Shadow->classID, NULL);
        shadow->position.x  = ring->position.x;
        shadow->position.y  = ring->position.y;
        shadow->parent      = (Entity *)ring;
        shadow->shadowScale = 0xC0;
    }

    foreach_all(UFO_Sphere, sphere)
    {
        EntityUFO_Shadow *shadow = RSDK_GET_ENTITY(slot--, UFO_Shadow);
        RSDK.ResetEntity(shadow, UFO_Shadow->classID, NULL);
        shadow->position.x  = sphere->position.x;
        shadow->position.y  = sphere->position.y;
        shadow->parent      = (Entity *)sphere;
        shadow->shadowScale = 0x100;
    }

    LogHelpers_Print("%d shadow entities spawned", TEMPENTITY_START - slot);
}

#if GAME_INCLUDE_EDITOR
void UFO_Shadow_EditorDraw(void) {}

void UFO_Shadow_EditorLoad(void) {}
#endif

void UFO_Shadow_Serialize(void) {}
