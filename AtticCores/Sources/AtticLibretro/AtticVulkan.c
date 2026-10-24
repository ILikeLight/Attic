// The frontend side of libretro's Vulkan rendering (RETRO_HW_CONTEXT_VULKAN), on MoltenVK.
//
// The core draws into its own image and hands it over with set_image before each frame.
// attic_vulkan_finish_frame copies that image into memory the app can read and returns the
// frame before it, so the copy is nearly always done by then and the CPU seldom waits for the
// GPU. This is the Vulkan counterpart of GLRenderer, which does the same for OpenGL ES.

#include "AtticLibretro.h"

#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
// MoltenVK's VK_KHR_portability_subset is still among Vulkan's beta extensions.
#define VK_ENABLE_BETA_EXTENSIONS
// The surface handed to cores is a Metal one (VK_EXT_metal_surface).
#define VK_USE_PLATFORM_METAL_EXT
#include <libretro_vulkan.h>

/// Frames in flight: the sync indices the core sees.
#define FRAMES 2
/// Room for what a core hands over per frame; libretro cores use one or two.
#define MAX_HANDOVER 16

typedef struct {
    VkCommandBuffer command;
    VkFence fence;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize capacity;
    void *mapped;
    bool coherent;
    unsigned width;
    unsigned height;
    bool red_first;
    /// A copy was submitted and its frame has not been handed out yet.
    bool pending;
} Slot;

struct AtticVulkan {
    struct retro_hw_render_interface_vulkan interface;
    const struct retro_hw_render_context_negotiation_interface_vulkan *negotiation;
    bool core_made_device;
    VkInstance instance;
    /// A surface on a Metal layer that is never shown: cores such as Dolphin only build their
    /// (libretro-faked) swapchain when the frontend hands them a surface, as RetroArch does.
    VkSurfaceKHR surface;
    id layer;
    VkPhysicalDevice gpu;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family;
    VkCommandPool pool;
    /// The core may submit to the queue from its own threads (lock_queue and unlock_queue).
    pthread_mutex_t queue_lock;
    Slot slots[FRAMES];
    uint32_t index;

    // What the core handed over for the next frame.
    struct retro_vulkan_image image;
    bool has_image;
    uint32_t image_queue_family;
    VkSemaphore wait_semaphores[MAX_HANDOVER];
    uint32_t wait_count;
    VkCommandBuffer core_commands[MAX_HANDOVER];
    uint32_t core_command_count;
    VkSemaphore signal_semaphore;
};

// MARK: The interface for the core

static void set_image(void *handle, const struct retro_vulkan_image *image, uint32_t num_semaphores,
                      const VkSemaphore *semaphores, uint32_t src_queue_family) {
    AtticVulkan *vulkan = handle;
    vulkan->has_image = image != NULL;
    if (image) {
        vulkan->image = *image;
    }
    vulkan->wait_count = num_semaphores < MAX_HANDOVER ? num_semaphores : MAX_HANDOVER;
    if (vulkan->wait_count) {
        memcpy(vulkan->wait_semaphores, semaphores, vulkan->wait_count * sizeof(VkSemaphore));
    }
    vulkan->image_queue_family = src_queue_family;
}

static uint32_t get_sync_index(void *handle) {
    return ((AtticVulkan *)handle)->index;
}

static uint32_t get_sync_index_mask(void *handle) {
    (void)handle;
    return (1u << FRAMES) - 1;
}

static void set_command_buffers(void *handle, uint32_t num_cmd, const VkCommandBuffer *cmd) {
    AtticVulkan *vulkan = handle;
    vulkan->core_command_count = num_cmd < MAX_HANDOVER ? num_cmd : MAX_HANDOVER;
    if (vulkan->core_command_count) {
        memcpy(vulkan->core_commands, cmd, vulkan->core_command_count * sizeof(VkCommandBuffer));
    }
}

static void wait_sync_index(void *handle) {
    AtticVulkan *vulkan = handle;
    vkWaitForFences(vulkan->device, 1, &vulkan->slots[vulkan->index].fence, VK_TRUE, UINT64_MAX);
}

static void lock_queue(void *handle) {
    pthread_mutex_lock(&((AtticVulkan *)handle)->queue_lock);
}

static void unlock_queue(void *handle) {
    pthread_mutex_unlock(&((AtticVulkan *)handle)->queue_lock);
}

static void set_signal_semaphore(void *handle, VkSemaphore semaphore) {
    ((AtticVulkan *)handle)->signal_semaphore = semaphore;
}

// MARK: Instance and device

static bool has_instance_extension(const char *name) {
    uint32_t count = 0;
    vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);
    VkExtensionProperties *extensions = calloc(count, sizeof *extensions);
    vkEnumerateInstanceExtensionProperties(NULL, &count, extensions);
    bool found = false;
    for (uint32_t i = 0; i < count && !found; i++) {
        found = strcmp(extensions[i].extensionName, name) == 0;
    }
    free(extensions);
    return found;
}

static bool has_device_extension(VkPhysicalDevice gpu, const char *name) {
    uint32_t count = 0;
    vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, NULL);
    VkExtensionProperties *extensions = calloc(count, sizeof *extensions);
    vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, extensions);
    bool found = false;
    for (uint32_t i = 0; i < count && !found; i++) {
        found = strcmp(extensions[i].extensionName, name) == 0;
    }
    free(extensions);
    return found;
}

static bool has_name(const char *const *names, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp(names[i], name) == 0) {
            return true;
        }
    }
    return false;
}

/// Creates an instance with what the core asked for, plus MoltenVK's portability enumeration.
/// It is at least Vulkan 1.1, with VK_KHR_get_physical_device_properties2: Dolphin asks for 1.0
/// without it, and then MoltenVK hides vkGetPhysicalDeviceMemoryProperties2, which Dolphin's
/// memory allocator needs. A core made for 1.0 runs on 1.1 unchanged.
static VkInstance create_instance(const VkInstanceCreateInfo *requested) {
    VkInstanceCreateInfo info = *requested;
    VkApplicationInfo application = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO};
    if (requested->pApplicationInfo) {
        application = *requested->pApplicationInfo;
    }
    if (application.apiVersion < VK_API_VERSION_1_1) {
        application.apiVersion = VK_API_VERSION_1_1;
    }
    info.pApplicationInfo = &application;
    const char *names[64];
    uint32_t count = 0;
    for (uint32_t i = 0; i < requested->enabledExtensionCount && count < 60; i++) {
        names[count++] = requested->ppEnabledExtensionNames[i];
    }
    // Also what the surface for the core needs (see make_surface).
    const char *wanted[] = {VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME, VK_KHR_SURFACE_EXTENSION_NAME,
                            VK_EXT_METAL_SURFACE_EXTENSION_NAME};
    for (size_t i = 0; i < sizeof wanted / sizeof *wanted && count < 62; i++) {
        if (!has_name(names, count, wanted[i]) && has_instance_extension(wanted[i])) {
            names[count++] = wanted[i];
        }
    }
    if (has_instance_extension(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        if (!has_name(names, count, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
            names[count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        }
        info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    info.enabledExtensionCount = count;
    info.ppEnabledExtensionNames = names;
    VkInstance instance = VK_NULL_HANDLE;
    return vkCreateInstance(&info, NULL, &instance) == VK_SUCCESS ? instance : VK_NULL_HANDLE;
}

static VkInstance create_instance_wrapper(void *opaque, const VkInstanceCreateInfo *create_info) {
    (void)opaque;
    return create_instance(create_info);
}

/// Creates a device with what the core asked for; MoltenVK's portability subset must be enabled.
static VkDevice create_device_wrapper(VkPhysicalDevice gpu, void *opaque, const VkDeviceCreateInfo *create_info) {
    (void)opaque;
    VkDeviceCreateInfo info = *create_info;
    const char *names[64];
    uint32_t count = 0;
    bool portability = false;
    for (uint32_t i = 0; i < create_info->enabledExtensionCount && count < 63; i++) {
        names[count++] = create_info->ppEnabledExtensionNames[i];
        portability |= strcmp(names[count - 1], VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME) == 0;
    }
    if (!portability && has_device_extension(gpu, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) {
        names[count++] = VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME;
    }
    info.enabledExtensionCount = count;
    info.ppEnabledExtensionNames = names;
    VkDevice device = VK_NULL_HANDLE;
    return vkCreateDevice(gpu, &info, NULL, &device) == VK_SUCCESS ? device : VK_NULL_HANDLE;
}

/// The device Attic makes itself when the core does not: one graphics queue.
static bool create_default_device(AtticVulkan *vulkan) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(vulkan->gpu, &count, NULL);
    VkQueueFamilyProperties *families = calloc(count, sizeof *families);
    vkGetPhysicalDeviceQueueFamilyProperties(vulkan->gpu, &count, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < count && family == UINT32_MAX; i++) {
        if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            family = i;
        }
    }
    free(families);
    if (family == UINT32_MAX) {
        return false;
    }
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
    };
    vulkan->device = create_device_wrapper(vulkan->gpu, NULL, &info);
    if (!vulkan->device) {
        return false;
    }
    vkGetDeviceQueue(vulkan->device, family, 0, &vulkan->queue);
    vulkan->queue_family = family;
    return true;
}

/// The surface for the core, on a CAMetalLayer of its own; it stays VK_NULL_HANDLE when the
/// instance lacks VK_EXT_metal_surface. The core never presents to it: libretro cores fake their
/// swapchain and hand each picture over with set_image.
static void make_surface(AtticVulkan *vulkan) {
    PFN_vkCreateMetalSurfaceEXT create_metal_surface =
        (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr(vulkan->instance, "vkCreateMetalSurfaceEXT");
    Class layer_class = objc_getClass("CAMetalLayer");
    if (!create_metal_surface || !layer_class) {
        return;
    }
    vulkan->layer = ((id (*)(Class, SEL))objc_msgSend)(layer_class, sel_registerName("new"));
    VkMetalSurfaceCreateInfoEXT info = {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pLayer = (const CAMetalLayer *)vulkan->layer,
    };
    if (!vulkan->layer || create_metal_surface(vulkan->instance, &info, NULL, &vulkan->surface) != VK_SUCCESS) {
        vulkan->surface = VK_NULL_HANDLE;
    }
}

static bool create_device(AtticVulkan *vulkan) {
    const struct retro_hw_render_context_negotiation_interface_vulkan *negotiation = vulkan->negotiation;
    struct retro_vulkan_context context = {0};
    bool made = false;
    make_surface(vulkan);
    if (negotiation && negotiation->interface_version >= 2 && negotiation->create_device2) {
        made = negotiation->create_device2(&context, vulkan->instance, vulkan->gpu, vulkan->surface, vkGetInstanceProcAddr,
                                           create_device_wrapper, vulkan);
    } else if (negotiation && negotiation->create_device) {
        const char *required[1];
        unsigned required_count = 0;
        if (has_device_extension(vulkan->gpu, VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) {
            required[required_count++] = VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME;
        }
        made = negotiation->create_device(&context, vulkan->instance, vulkan->gpu, vulkan->surface, vkGetInstanceProcAddr,
                                          required, required_count, NULL, 0, NULL);
    }
    if (made) {
        vulkan->core_made_device = true;
        vulkan->gpu = context.gpu ? context.gpu : vulkan->gpu;
        vulkan->device = context.device;
        vulkan->queue = context.queue;
        vulkan->queue_family = context.queue_family_index;
        return true;
    }
    // As libretro asks: without a device from the core, make the usual one.
    return create_default_device(vulkan);
}

AtticVulkan *attic_vulkan_create(const void *negotiation_interface) {
    AtticVulkan *vulkan = calloc(1, sizeof *vulkan);
    pthread_mutex_init(&vulkan->queue_lock, NULL);
    const struct retro_hw_render_context_negotiation_interface_vulkan *negotiation = negotiation_interface;
    if (negotiation && negotiation->interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) {
        vulkan->negotiation = negotiation;
    }

    static const VkApplicationInfo attic = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Attic",
        .pEngineName = "Attic",
        .apiVersion = VK_API_VERSION_1_1,
    };
    const VkApplicationInfo *application = vulkan->negotiation && vulkan->negotiation->get_application_info
        ? vulkan->negotiation->get_application_info() : NULL;
    if (!application) {
        application = &attic;
    }
    if (vulkan->negotiation && vulkan->negotiation->interface_version >= 2 && vulkan->negotiation->create_instance) {
        vulkan->instance = vulkan->negotiation->create_instance(vkGetInstanceProcAddr, application,
                                                                create_instance_wrapper, vulkan);
    } else {
        VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = application};
        vulkan->instance = create_instance(&info);
    }
    uint32_t gpus = 1;
    if (!vulkan->instance || vkEnumeratePhysicalDevices(vulkan->instance, &gpus, &vulkan->gpu) < 0 || gpus == 0 ||
        !create_device(vulkan)) {
        attic_vulkan_destroy(vulkan);
        return NULL;
    }

    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = vulkan->queue_family,
    };
    if (vkCreateCommandPool(vulkan->device, &pool, NULL, &vulkan->pool) != VK_SUCCESS) {
        attic_vulkan_destroy(vulkan);
        return NULL;
    }
    for (int i = 0; i < FRAMES; i++) {
        VkCommandBufferAllocateInfo allocate = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = vulkan->pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
        if (vkAllocateCommandBuffers(vulkan->device, &allocate, &vulkan->slots[i].command) != VK_SUCCESS ||
            vkCreateFence(vulkan->device, &fence, NULL, &vulkan->slots[i].fence) != VK_SUCCESS) {
            attic_vulkan_destroy(vulkan);
            return NULL;
        }
    }

    vulkan->interface = (struct retro_hw_render_interface_vulkan){
        .interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN,
        .interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION,
        .handle = vulkan,
        .instance = vulkan->instance,
        .gpu = vulkan->gpu,
        .device = vulkan->device,
        .get_device_proc_addr = vkGetDeviceProcAddr,
        .get_instance_proc_addr = vkGetInstanceProcAddr,
        .queue = vulkan->queue,
        .queue_index = vulkan->queue_family,
        .set_image = set_image,
        .get_sync_index = get_sync_index,
        .get_sync_index_mask = get_sync_index_mask,
        .set_command_buffers = set_command_buffers,
        .wait_sync_index = wait_sync_index,
        .lock_queue = lock_queue,
        .unlock_queue = unlock_queue,
        .set_signal_semaphore = set_signal_semaphore,
    };
    return vulkan;
}

void attic_vulkan_destroy(AtticVulkan *vulkan) {
    if (!vulkan) {
        return;
    }
    if (vulkan->device) {
        vkDeviceWaitIdle(vulkan->device);
        for (int i = 0; i < FRAMES; i++) {
            Slot *slot = &vulkan->slots[i];
            if (slot->buffer) vkDestroyBuffer(vulkan->device, slot->buffer, NULL);
            if (slot->memory) vkFreeMemory(vulkan->device, slot->memory, NULL);
            if (slot->fence) vkDestroyFence(vulkan->device, slot->fence, NULL);
        }
        if (vulkan->pool) vkDestroyCommandPool(vulkan->device, vulkan->pool, NULL);
    }
    // The device belongs to the frontend, even when the core made it; the core frees its own extras first.
    if (vulkan->core_made_device && vulkan->negotiation->destroy_device) {
        vulkan->negotiation->destroy_device();
    }
    if (vulkan->device) vkDestroyDevice(vulkan->device, NULL);
    if (vulkan->surface) vkDestroySurfaceKHR(vulkan->instance, vulkan->surface, NULL);
    if (vulkan->layer) ((void (*)(id, SEL))objc_msgSend)(vulkan->layer, sel_registerName("release"));
    if (vulkan->instance) vkDestroyInstance(vulkan->instance, NULL);
    pthread_mutex_destroy(&vulkan->queue_lock);
    free(vulkan);
}

const void *attic_vulkan_interface(AtticVulkan *vulkan) {
    return &vulkan->interface;
}

// MARK: Frames

/// Makes sure the slot has a buffer the CPU can read of at least `size` bytes.
static bool reserve(AtticVulkan *vulkan, Slot *slot, VkDeviceSize size) {
    if (slot->capacity >= size) {
        return true;
    }
    if (slot->buffer) vkDestroyBuffer(vulkan->device, slot->buffer, NULL);
    if (slot->memory) vkFreeMemory(vulkan->device, slot->memory, NULL);
    slot->buffer = VK_NULL_HANDLE;
    slot->memory = VK_NULL_HANDLE;
    slot->capacity = 0;

    VkBufferCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (vkCreateBuffer(vulkan->device, &info, NULL, &slot->buffer) != VK_SUCCESS) {
        return false;
    }
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(vulkan->device, slot->buffer, &requirements);
    VkPhysicalDeviceMemoryProperties memory;
    vkGetPhysicalDeviceMemoryProperties(vulkan->gpu, &memory);
    // Memory the CPU can see, cached for fast reading if there is such memory.
    uint32_t chosen = UINT32_MAX;
    for (int pass = 0; pass < 2 && chosen == UINT32_MAX; pass++) {
        VkMemoryPropertyFlags wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | (pass == 0 ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0);
        for (uint32_t i = 0; i < memory.memoryTypeCount && chosen == UINT32_MAX; i++) {
            if ((requirements.memoryTypeBits & (1u << i)) && (memory.memoryTypes[i].propertyFlags & wanted) == wanted) {
                chosen = i;
            }
        }
    }
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = chosen,
    };
    if (chosen == UINT32_MAX || vkAllocateMemory(vulkan->device, &allocate, NULL, &slot->memory) != VK_SUCCESS ||
        vkBindBufferMemory(vulkan->device, slot->buffer, slot->memory, 0) != VK_SUCCESS ||
        vkMapMemory(vulkan->device, slot->memory, 0, VK_WHOLE_SIZE, 0, &slot->mapped) != VK_SUCCESS) {
        return false;
    }
    slot->coherent = (memory.memoryTypes[chosen].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    slot->capacity = size;
    return true;
}

/// Records the copy of the core's image into the slot's buffer; false if the image cannot be copied.
static bool record_copy(AtticVulkan *vulkan, Slot *slot, unsigned width, unsigned height) {
    const VkImageViewCreateInfo *view = &vulkan->image.create_info;
    bool red_first;
    switch (view->format) {
    case VK_FORMAT_B8G8R8A8_UNORM:
    case VK_FORMAT_B8G8R8A8_SRGB:
        red_first = false;
        break;
    case VK_FORMAT_R8G8B8A8_UNORM:
    case VK_FORMAT_R8G8B8A8_SRGB:
    case VK_FORMAT_A8B8G8R8_UNORM_PACK32:
    case VK_FORMAT_A8B8G8R8_SRGB_PACK32:
        red_first = true;
        break;
    default:
        return false;
    }
    if (!vulkan->has_image || width == 0 || height == 0 || !reserve(vulkan, slot, (VkDeviceSize)width * height * 4)) {
        return false;
    }

    // The core keeps its image in its own layout (and maybe queue family); borrow it for the copy.
    uint32_t theirs = vulkan->image_queue_family, ours = vulkan->queue_family;
    bool transfer = theirs != VK_QUEUE_FAMILY_IGNORED && theirs != ours;
    VkImageSubresourceRange range = {
        .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = view->subresourceRange.baseMipLevel,
        .levelCount = 1,
        .baseArrayLayer = view->subresourceRange.baseArrayLayer,
        .layerCount = 1,
    };
    VkImageMemoryBarrier borrow = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = vulkan->image.image_layout,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = transfer ? theirs : VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = transfer ? ours : VK_QUEUE_FAMILY_IGNORED,
        .image = view->image,
        .subresourceRange = range,
    };
    vkCmdPipelineBarrier(slot->command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 1, &borrow);
    VkBufferImageCopy region = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, range.baseMipLevel, range.baseArrayLayer, 1},
        .imageExtent = {width, height, 1},
    };
    vkCmdCopyImageToBuffer(slot->command, view->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, slot->buffer, 1, &region);
    VkImageMemoryBarrier give_back = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .newLayout = vulkan->image.image_layout,
        .srcQueueFamilyIndex = transfer ? ours : VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = transfer ? theirs : VK_QUEUE_FAMILY_IGNORED,
        .image = view->image,
        .subresourceRange = range,
    };
    VkBufferMemoryBarrier readable = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = slot->buffer,
        .size = VK_WHOLE_SIZE,
    };
    vkCmdPipelineBarrier(slot->command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0,
                         0, NULL, 1, &readable, 1, &give_back);
    slot->width = width;
    slot->height = height;
    slot->red_first = red_first;
    return true;
}

bool attic_vulkan_finish_frame(AtticVulkan *vulkan, unsigned width, unsigned height, AtticVulkanFrame *frame) {
    Slot *slot = &vulkan->slots[vulkan->index];
    vkWaitForFences(vulkan->device, 1, &slot->fence, VK_TRUE, UINT64_MAX);
    vkResetFences(vulkan->device, 1, &slot->fence);
    vkResetCommandBuffer(slot->command, 0);
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(slot->command, &begin);
    bool copying = record_copy(vulkan, slot, width, height);
    vkEndCommandBuffer(slot->command);

    // The core's own command buffers go first, then the copy; the fence also tells the core
    // (wait_sync_index) when the GPU is done with this frame.
    VkCommandBuffer commands[MAX_HANDOVER + 1];
    memcpy(commands, vulkan->core_commands, vulkan->core_command_count * sizeof(VkCommandBuffer));
    commands[vulkan->core_command_count] = slot->command;
    VkPipelineStageFlags stages[MAX_HANDOVER];
    for (uint32_t i = 0; i < vulkan->wait_count; i++) {
        stages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    }
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = vulkan->wait_count,
        .pWaitSemaphores = vulkan->wait_semaphores,
        .pWaitDstStageMask = stages,
        .commandBufferCount = vulkan->core_command_count + 1,
        .pCommandBuffers = commands,
        .signalSemaphoreCount = vulkan->signal_semaphore ? 1 : 0,
        .pSignalSemaphores = &vulkan->signal_semaphore,
    };
    pthread_mutex_lock(&vulkan->queue_lock);
    VkResult submitted = vkQueueSubmit(vulkan->queue, 1, &submit, slot->fence);
    pthread_mutex_unlock(&vulkan->queue_lock);
    // What the core handed over is used once.
    vulkan->wait_count = 0;
    vulkan->core_command_count = 0;
    vulkan->signal_semaphore = VK_NULL_HANDLE;
    slot->pending = copying && submitted == VK_SUCCESS;
    if (submitted != VK_SUCCESS) {
        // Leave the fence signalled, or the next wait on this slot would never end.
        VkSubmitInfo nothing = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO};
        pthread_mutex_lock(&vulkan->queue_lock);
        vkQueueSubmit(vulkan->queue, 1, &nothing, slot->fence);
        pthread_mutex_unlock(&vulkan->queue_lock);
    }

    // Hand out the frame before this one.
    Slot *previous = &vulkan->slots[(vulkan->index + FRAMES - 1) % FRAMES];
    vulkan->index = (vulkan->index + 1) % FRAMES;
    if (!previous->pending) {
        return false;
    }
    previous->pending = false;
    vkWaitForFences(vulkan->device, 1, &previous->fence, VK_TRUE, UINT64_MAX);
    if (!previous->coherent) {
        VkMappedMemoryRange range = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = previous->memory, .size = VK_WHOLE_SIZE};
        vkInvalidateMappedMemoryRanges(vulkan->device, 1, &range);
    }
    frame->pixels = previous->mapped;
    frame->width = previous->width;
    frame->height = previous->height;
    frame->pitch = (size_t)previous->width * 4;
    frame->red_first = previous->red_first;
    return true;
}
